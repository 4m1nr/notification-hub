// Command rss-relay receives Miniflux webhook deliveries and republishes each new
// entry as an ntfy notification on the "rss" topic.
//
// It listens on loopback only: Miniflux runs on the same host, so there is no
// reason to expose this through the reverse proxy.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/4m1nr/notification-hub/internal/config"
	"github.com/4m1nr/notification-hub/internal/hc"
	"github.com/4m1nr/notification-hub/internal/logx"
	"github.com/4m1nr/notification-hub/internal/ntfy"
)

// maxBodyBytes caps how much of a webhook delivery we will read. Miniflux batches
// entries per feed, so this is generous, but it must be bounded.
const maxBodyBytes = 8 << 20 // 8 MiB

// webhookPayload is the subset of Miniflux's webhook body we use.
type webhookPayload struct {
	EventType string `json:"event_type"`
	Feed      *struct {
		ID       int64  `json:"id"`
		Title    string `json:"title"`
		SiteURL  string `json:"site_url"`
		FeedURL  string `json:"feed_url"`
		Category *struct {
			Title string `json:"title"`
		} `json:"category"`
	} `json:"feed"`
	Entries []struct {
		ID     int64  `json:"id"`
		Title  string `json:"title"`
		URL    string `json:"url"`
		Author string `json:"author"`
		Feed   *struct {
			Title string `json:"title"`
		} `json:"feed"`
	} `json:"entries"`
	// Present on the "save_entry" event, which delivers a single entry.
	Entry *struct {
		ID    int64  `json:"id"`
		Title string `json:"title"`
		URL   string `json:"url"`
		Feed  *struct {
			Title string `json:"title"`
		} `json:"feed"`
	} `json:"entry"`
}

type relay struct {
	secret []byte
	topic  string
	tags   []string
	ntfy   *ntfy.Client
	log    *slog.Logger
}

func main() {
	log := logx.Setup("rss-relay")

	if exe, err := os.Executable(); err == nil {
		_ = config.LoadDotEnv(filepath.Join(filepath.Dir(exe), ".env"))
	}

	cfg := config.New()
	var (
		listen    = cfg.Optional("RSS_RELAY_LISTEN", "127.0.0.1:8181")
		ntfyURL   = cfg.Required("NTFY_URL")
		ntfyToken = cfg.Required("NTFY_TOKEN_RSS")
		topic     = cfg.Optional("NTFY_TOPIC_RSS", "rss")
		secret    = cfg.Required("MINIFLUX_WEBHOOK_SECRET")
		hcURL     = cfg.Optional("HC_PING_URL_RSS", "")
		hcEvery   = cfg.Duration("HC_INTERVAL", 5*time.Minute)
	)
	if err := cfg.Err(); err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	r := &relay{
		secret: []byte(secret),
		topic:  topic,
		tags:   []string{"newspaper"},
		ntfy:   ntfy.NewClient(ntfyURL, ntfyToken, log),
		log:    log,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /webhook", r.handleWebhook)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = io.WriteString(w, "ok\n")
	})

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// The relay is idle by nature — it only runs when Miniflux delivers — so its
	// dead-man's-switch is a plain timer gated on the process being up. If the
	// process dies, systemd restarts it; if that fails too, the check goes red.
	hb := &hc.Heartbeat{
		Client:   hc.NewClient(hcURL, log),
		Interval: hcEvery,
		Alive:    func() bool { return true },
		Log:      log,
	}
	go hb.Run(ctx)

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Info("listening", "addr", listen, "topic", topic)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("server failed", "error", err)
		os.Exit(1)
	}
	log.Info("shut down")
}

func (r *relay) handleWebhook(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBodyBytes))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}

	// The HMAC signature is the only authentication on this endpoint, so it is
	// verified before the body is parsed, and with a constant-time comparison.
	if !r.validSignature(req.Header.Get("X-Miniflux-Signature"), body) {
		r.log.Warn("rejected webhook with invalid signature", "remote", req.RemoteAddr)
		http.Error(w, "invalid signature", http.StatusUnauthorized)
		return
	}

	var payload webhookPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		r.log.Warn("unparseable webhook body", "error", err)
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}

	// Answer Miniflux before publishing: it retries on a non-2xx, and duplicate
	// notifications are worse than a dropped one here.
	w.WriteHeader(http.StatusNoContent)

	msgs := r.messages(payload)
	if len(msgs) == 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		for _, m := range msgs {
			if err := r.ntfy.Publish(ctx, m); err != nil {
				r.log.Error("publish failed", "title", m.Message, "error", err)
			}
		}
		r.log.Info("relayed entries", "count", len(msgs), "event", payload.EventType)
	}()
}

func (r *relay) validSignature(header string, body []byte) bool {
	if header == "" {
		return false
	}
	got, err := hex.DecodeString(strings.TrimSpace(header))
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, r.secret)
	mac.Write(body)
	return hmac.Equal(got, mac.Sum(nil))
}

// messages converts a payload into one notification per entry. The feed name is
// the title and the entry title is the body, so the phone's notification shade
// groups sensibly by source.
func (r *relay) messages(p webhookPayload) []ntfy.Message {
	feedTitle := "RSS"
	if p.Feed != nil && p.Feed.Title != "" {
		feedTitle = p.Feed.Title
	}

	var out []ntfy.Message
	add := func(title, url, perEntryFeed string) {
		name := feedTitle
		if perEntryFeed != "" {
			name = perEntryFeed
		}
		if title == "" {
			title = "(untitled entry)"
		}
		out = append(out, ntfy.Message{
			Topic:   r.topic,
			Title:   name,
			Message: title,
			Click:   url,
			Tags:    r.tags,
		})
	}

	switch p.EventType {
	case "new_entries", "":
		for _, e := range p.Entries {
			var per string
			if e.Feed != nil {
				per = e.Feed.Title
			}
			add(e.Title, e.URL, per)
		}
	case "save_entry":
		if p.Entry != nil {
			var per string
			if p.Entry.Feed != nil {
				per = p.Entry.Feed.Title
			}
			add(p.Entry.Title, p.Entry.URL, per)
		}
	default:
		r.log.Debug("ignoring event type", "event", p.EventType)
	}
	return out
}
