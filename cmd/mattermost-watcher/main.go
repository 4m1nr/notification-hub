// Command mattermost-watcher holds a WebSocket connection to the office
// Mattermost instance and publishes matching messages to the ntfy "mattermost"
// topic.
//
// It authenticates with a Personal Access Token, so it needs no admin rights on
// the server — a regular account with PATs enabled is enough.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/mattermost/mattermost/server/public/model"

	"github.com/4m1nr/notification-hub/internal/config"
	"github.com/4m1nr/notification-hub/internal/hc"
	"github.com/4m1nr/notification-hub/internal/logx"
	"github.com/4m1nr/notification-hub/internal/ntfy"
)

// maxPreview bounds how much of a message body ends up in the notification.
const maxPreview = 300

type watcher struct {
	serverURL string
	wsURL     string
	token     string

	// notifyMentions publishes any post that mentions me, in any channel.
	notifyMentions bool
	// channels is an allowlist of channel names (the URL slug, not the display
	// name). Empty means "no channel is watched wholesale".
	channels map[string]bool
	// notifyDMs publishes every direct and group message.
	notifyDMs bool

	me    *model.User
	topic string
	ntfy  *ntfy.Client
	log   *slog.Logger

	connected atomic.Bool
}

func main() {
	log := logx.Setup("mattermost-watcher")

	if exe, err := os.Executable(); err == nil {
		_ = config.LoadDotEnv(filepath.Join(filepath.Dir(exe), ".env"))
	}

	cfg := config.New()
	var (
		serverURL = cfg.Required("MATTERMOST_URL") // https://mattermost.example.com
		token     = cfg.Required("MATTERMOST_TOKEN")
		mentions  = cfg.Bool("MATTERMOST_NOTIFY_MENTIONS", true)
		dms       = cfg.Bool("MATTERMOST_NOTIFY_DMS", true)
		chans     = cfg.List("MATTERMOST_CHANNELS")
		ntfyURL   = cfg.Required("NTFY_URL")
		ntfyToken = cfg.Required("NTFY_TOKEN_MATTERMOST")
		topic     = cfg.Optional("NTFY_TOPIC_MATTERMOST", "mattermost")
		hcURL     = cfg.Optional("HC_PING_URL_MATTERMOST", "")
		hcEvery   = cfg.Duration("HC_INTERVAL", 5*time.Minute)
	)
	if err := cfg.Err(); err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	w := &watcher{
		serverURL:      strings.TrimRight(serverURL, "/"),
		token:          token,
		notifyMentions: mentions,
		notifyDMs:      dms,
		channels:       toSet(chans),
		topic:          topic,
		ntfy:           ntfy.NewClient(ntfyURL, ntfyToken, log),
		log:            log,
	}
	w.wsURL = toWebSocketURL(w.serverURL)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	hb := &hc.Heartbeat{
		Client:   hc.NewClient(hcURL, log),
		Interval: hcEvery,
		Alive:    w.connected.Load,
		Log:      log,
	}
	go hb.Run(ctx)

	w.run(ctx)
	log.Info("shut down")
}

// run reconnects forever with exponential backoff. A corporate network drops
// long-lived WebSockets routinely, so reconnecting is the normal case, not an
// error path.
func (w *watcher) run(ctx context.Context) {
	const (
		minBackoff = 5 * time.Second
		maxBackoff = 5 * time.Minute
	)
	backoff := minBackoff

	for ctx.Err() == nil {
		start := time.Now()
		if err := w.session(ctx); err != nil && ctx.Err() == nil {
			w.log.Error("session ended", "error", err)
		}
		w.connected.Store(false)
		if ctx.Err() != nil {
			return
		}

		if time.Since(start) > 5*time.Minute {
			backoff = minBackoff
		}
		w.log.Info("reconnecting", "in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

func (w *watcher) session(ctx context.Context) error {
	// Resolve our own identity each time: it tells us which mentions are ours,
	// and doubles as a check that the PAT is still valid before we open a socket.
	api := model.NewAPIv4Client(w.serverURL)
	api.SetToken(w.token)

	meCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	me, _, err := api.GetMe(meCtx, "")
	cancel()
	if err != nil {
		return fmt.Errorf("authenticating with personal access token: %w", err)
	}
	w.me = me

	ws, aerr := model.NewWebSocketClient4(w.wsURL, w.token)
	if aerr != nil {
		return fmt.Errorf("websocket connect: %w", aerr)
	}
	defer ws.Close()

	ws.Listen()
	w.connected.Store(true)
	w.log.Info("connected", "user", me.Username, "server", w.serverURL)

	for {
		select {
		case <-ctx.Done():
			return nil

		case <-ws.PingTimeoutChannel:
			// Documented as required reading; an unread ping timeout deadlocks
			// the client. A timeout means the server stopped answering.
			return fmt.Errorf("websocket ping timeout")

		case resp, ok := <-ws.ResponseChannel:
			if !ok {
				return w.listenError(ws)
			}
			_ = resp

		case ev, ok := <-ws.EventChannel:
			if !ok {
				return w.listenError(ws)
			}
			if ev.EventType() != model.WebsocketEventPosted {
				continue
			}
			if msg, want := w.evaluate(ev); want {
				if err := w.ntfy.Publish(ctx, msg); err != nil {
					w.log.Error("publish failed", "error", err)
				}
			}
		}
	}
}

func (w *watcher) listenError(ws *model.WebSocketClient) error {
	if ws.ListenError != nil {
		return fmt.Errorf("websocket closed: %s", ws.ListenError.Error())
	}
	return fmt.Errorf("websocket closed")
}

// evaluate decides whether a "posted" event deserves a notification, and renders
// it if so.
func (w *watcher) evaluate(ev *model.WebSocketEvent) (ntfy.Message, bool) {
	data := ev.GetData()

	raw, _ := data["post"].(string)
	if raw == "" {
		return ntfy.Message{}, false
	}
	var post model.Post
	if err := json.Unmarshal([]byte(raw), &post); err != nil {
		w.log.Warn("unparseable post payload", "error", err)
		return ntfy.Message{}, false
	}

	// Never notify about our own messages — otherwise every message sent from the
	// desktop app buzzes the phone.
	if w.me != nil && post.UserId == w.me.Id {
		return ntfy.Message{}, false
	}
	// System join/leave/header messages are noise.
	if post.Type != "" && strings.HasPrefix(post.Type, "system_") {
		return ntfy.Message{}, false
	}

	channelName, _ := data["channel_name"].(string)
	channelDisplay, _ := data["channel_display_name"].(string)
	channelType, _ := data["channel_type"].(string)
	senderName, _ := data["sender_name"].(string)

	reason, ok := w.match(data, channelName, channelType, post.Message)
	if !ok {
		return ntfy.Message{}, false
	}

	where := channelDisplay
	if where == "" {
		where = channelName
	}
	// Direct messages have a machine-generated channel name; the sender is the
	// only useful label.
	if model.ChannelType(channelType) == model.ChannelTypeDirect {
		where = "Direct message"
	}

	sender := strings.TrimSpace(senderName)
	if sender == "" {
		sender = "Mattermost"
	}

	title := fmt.Sprintf("%s · %s", sender, where)
	body := strings.TrimSpace(post.Message)
	if body == "" {
		body = "(no text — attachment or update)"
	}
	if len(body) > maxPreview {
		body = body[:maxPreview] + "…"
	}

	priority := 3
	tags := []string{"speech_balloon"}
	if reason == "mention" {
		priority = 4
		tags = []string{"bell"}
	}

	return ntfy.Message{
		Topic:    w.topic,
		Title:    title,
		Message:  body,
		Click:    fmt.Sprintf("%s/_redirect/pl/%s", w.serverURL, post.Id),
		Tags:     tags,
		Priority: priority,
	}, true
}

// match applies the configured filters, returning why the post matched.
func (w *watcher) match(data map[string]any, channelName, channelType, text string) (string, bool) {
	if w.notifyMentions && w.mentionsMe(data, text) {
		return "mention", true
	}
	if w.notifyDMs && (model.ChannelType(channelType) == model.ChannelTypeDirect || model.ChannelType(channelType) == model.ChannelTypeGroup) {
		return "dm", true
	}
	if w.channels[channelName] {
		return "channel", true
	}
	return "", false
}

// mentionsMe prefers the server's own "mentions" list, which already accounts for
// @here/@channel and keyword settings. It falls back to matching @username in the
// text, because that field is absent on some server versions.
func (w *watcher) mentionsMe(data map[string]any, text string) bool {
	if w.me == nil {
		return false
	}
	if raw, ok := data["mentions"].(string); ok && raw != "" {
		var ids []string
		if err := json.Unmarshal([]byte(raw), &ids); err == nil {
			for _, id := range ids {
				if id == w.me.Id {
					return true
				}
			}
			return false
		}
	}
	return strings.Contains(strings.ToLower(text), "@"+strings.ToLower(w.me.Username))
}

func toSet(items []string) map[string]bool {
	if len(items) == 0 {
		return nil
	}
	m := make(map[string]bool, len(items))
	for _, i := range items {
		m[strings.ToLower(strings.TrimSpace(i))] = true
	}
	return m
}

// toWebSocketURL converts the HTTP base URL into the ws:// form the client wants.
func toWebSocketURL(httpURL string) string {
	switch {
	case strings.HasPrefix(httpURL, "https://"):
		return "wss://" + strings.TrimPrefix(httpURL, "https://")
	case strings.HasPrefix(httpURL, "http://"):
		return "ws://" + strings.TrimPrefix(httpURL, "http://")
	default:
		return httpURL
	}
}
