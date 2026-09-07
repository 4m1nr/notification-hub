// Command mail-watcher holds an IMAP IDLE connection to the office mail account
// and publishes each newly arrived message to the ntfy "mail" topic.
//
// It runs on the office PC, which sits inside the corporate network, so it needs
// nothing but outbound HTTPS to reach the VPS.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"

	"github.com/4m1nr/notification-hub/internal/config"
	"github.com/4m1nr/notification-hub/internal/hc"
	"github.com/4m1nr/notification-hub/internal/logx"
	"github.com/4m1nr/notification-hub/internal/ntfy"
)

// maxBatch caps how many messages one wake-up will announce individually. A
// mailbox that receives 200 messages at once should produce a summary, not 200
// buzzes.
const maxBatch = 10

type watcher struct {
	server   string
	username string
	password string
	mailbox  string

	topic string
	ntfy  *ntfy.Client
	log   *slog.Logger

	// connected drives the dead-man's-switch: the heartbeat only pings while an
	// IMAP session is actually established.
	connected atomic.Bool
}

func main() {
	log := logx.Setup("mail-watcher")

	if exe, err := os.Executable(); err == nil {
		_ = config.LoadDotEnv(filepath.Join(filepath.Dir(exe), ".env"))
	}

	cfg := config.New()
	var (
		server    = cfg.Required("IMAP_SERVER") // host:993
		username  = cfg.Required("IMAP_USERNAME")
		password  = cfg.Required("IMAP_PASSWORD")
		mailbox   = cfg.Optional("IMAP_MAILBOX", "INBOX")
		ntfyURL   = cfg.Required("NTFY_URL")
		ntfyToken = cfg.Required("NTFY_TOKEN_MAIL")
		topic     = cfg.Optional("NTFY_TOPIC_MAIL", "mail")
		hcURL     = cfg.Optional("HC_PING_URL_MAIL", "")
		hcEvery   = cfg.Duration("HC_INTERVAL", 5*time.Minute)
	)
	if err := cfg.Err(); err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	w := &watcher{
		server:   server,
		username: username,
		password: password,
		mailbox:  mailbox,
		topic:    topic,
		ntfy:     ntfy.NewClient(ntfyURL, ntfyToken, log),
		log:      log,
	}

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

// run reconnects forever with exponential backoff. systemd restarts the process
// on a hard failure, but transient network blips are far more common than crashes
// and are better handled in-process, without losing the backoff state.
func (w *watcher) run(ctx context.Context) {
	const (
		minBackoff = 5 * time.Second
		maxBackoff = 5 * time.Minute
	)
	backoff := minBackoff

	for ctx.Err() == nil {
		start := time.Now()
		err := w.session(ctx)
		w.connected.Store(false)

		if ctx.Err() != nil {
			return
		}
		if err != nil {
			w.log.Error("imap session ended", "error", err)
		} else {
			w.log.Warn("imap session ended without error")
		}

		// A session that survived a while was healthy; don't punish it with the
		// backoff accumulated by earlier failures.
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

// session runs one connection: log in, select the mailbox, then idle until
// something arrives or the connection breaks.
func (w *watcher) session(ctx context.Context) error {
	var (
		mu       sync.Mutex
		lastSeen uint32
	)
	// updates is size 1 and written non-blockingly: the unilateral data handler
	// runs on the client's read loop and blocks it, so it must never wait.
	updates := make(chan struct{}, 1)
	notify := func() {
		select {
		case updates <- struct{}{}:
		default:
		}
	}

	options := &imapclient.Options{
		UnilateralDataHandler: &imapclient.UnilateralDataHandler{
			Mailbox: func(data *imapclient.UnilateralDataMailbox) {
				if data.NumMessages != nil {
					notify()
				}
			},
			Expunge: func(seqNum uint32) {
				// Sequence numbers shift down when a message is removed, so the
				// high-water mark has to shift with them or we would re-announce
				// old mail.
				mu.Lock()
				if seqNum <= lastSeen && lastSeen > 0 {
					lastSeen--
				}
				mu.Unlock()
			},
		},
	}

	c, err := imapclient.DialTLS(w.server, options)
	if err != nil {
		return fmt.Errorf("dial %s: %w", w.server, err)
	}
	defer c.Close()

	if err := c.Login(w.username, w.password).Wait(); err != nil {
		return fmt.Errorf("login: %w", err)
	}
	selected, err := c.Select(w.mailbox, nil).Wait()
	if err != nil {
		return fmt.Errorf("select %s: %w", w.mailbox, err)
	}

	// Start from the current message count: mail that arrived while we were down
	// is history, and replaying it on every restart would be its own kind of spam.
	mu.Lock()
	lastSeen = selected.NumMessages
	mu.Unlock()

	w.connected.Store(true)
	w.log.Info("connected", "mailbox", w.mailbox, "messages", selected.NumMessages)

	for {
		idleCmd, err := c.Idle()
		if err != nil {
			return fmt.Errorf("idle: %w", err)
		}

		idleDone := make(chan error, 1)
		go func() { idleDone <- idleCmd.Wait() }()

		select {
		case <-ctx.Done():
			_ = idleCmd.Close()
			<-idleDone
			return nil

		case err := <-idleDone:
			// IDLE ended on its own: the connection is gone.
			if err == nil {
				err = errors.New("idle stopped unexpectedly")
			}
			return err

		case <-updates:
			if err := idleCmd.Close(); err != nil {
				return fmt.Errorf("closing idle: %w", err)
			}
			<-idleDone

			mu.Lock()
			from := lastSeen + 1
			mu.Unlock()

			status, err := c.Status(w.mailbox, &imap.StatusOptions{NumMessages: true}).Wait()
			if err != nil {
				return fmt.Errorf("status: %w", err)
			}
			total := uint32(0)
			if status.NumMessages != nil {
				total = *status.NumMessages
			}
			if total < from {
				// Only expunges happened; resync and keep idling.
				mu.Lock()
				lastSeen = total
				mu.Unlock()
				continue
			}

			if err := w.announce(ctx, c, from, total); err != nil {
				return err
			}
			mu.Lock()
			lastSeen = total
			mu.Unlock()
		}
	}
}

// announce fetches envelopes for sequence numbers from..to and publishes them.
func (w *watcher) announce(ctx context.Context, c *imapclient.Client, from, to uint32) error {
	count := to - from + 1

	if count > maxBatch {
		// Summarise a flood rather than firing one notification per message.
		msg := ntfy.Message{
			Topic:    w.topic,
			Title:    fmt.Sprintf("%d new messages", count),
			Message:  fmt.Sprintf("%s received %d messages at once.", w.mailbox, count),
			Tags:     []string{"envelope"},
			Priority: 3,
		}
		if err := w.ntfy.Publish(ctx, msg); err != nil {
			w.log.Error("publish failed", "error", err)
		}
		return nil
	}

	var seqSet imap.SeqSet
	seqSet.AddRange(from, to)

	messages, err := c.Fetch(seqSet, &imap.FetchOptions{Envelope: true, UID: true}).Collect()
	if err != nil {
		return fmt.Errorf("fetch %d:%d: %w", from, to, err)
	}

	for _, m := range messages {
		if m.Envelope == nil {
			continue
		}
		subject := strings.TrimSpace(m.Envelope.Subject)
		if subject == "" {
			subject = "(no subject)"
		}
		if err := w.ntfy.Publish(ctx, ntfy.Message{
			Topic:    w.topic,
			Title:    sender(m.Envelope),
			Message:  subject,
			Tags:     []string{"envelope"},
			Priority: 3,
		}); err != nil {
			w.log.Error("publish failed", "subject", subject, "error", err)
		}
	}
	w.log.Info("announced new mail", "count", len(messages))
	return nil
}

// sender renders the From header as a display name, falling back to the address.
func sender(env *imap.Envelope) string {
	addrs := env.From
	if len(addrs) == 0 {
		addrs = env.Sender
	}
	if len(addrs) == 0 {
		return "New mail"
	}
	a := addrs[0]
	if name := strings.TrimSpace(a.Name); name != "" {
		return name
	}
	if addr := a.Addr(); addr != "" {
		return addr
	}
	return "New mail"
}
