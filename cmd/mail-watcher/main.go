// Command mail-watcher holds an IMAP IDLE connection to the office mail account
// and publishes each newly arrived message to the ntfy "mail" topic.
//
// It runs on the office PC, which sits inside the corporate network, so it needs
// nothing but outbound HTTPS to reach the VPS.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-message/mail"

	// Registers the legacy charsets (windows-1256, iso-8859-*, ...) that office
	// mail still arrives in, so go-message can decode them.
	_ "github.com/emersion/go-message/charset"

	"github.com/4m1nr/notification-hub/internal/config"
	"github.com/4m1nr/notification-hub/internal/hc"
	"github.com/4m1nr/notification-hub/internal/logx"
	"github.com/4m1nr/notification-hub/internal/ntfy"
)

// maxBatch caps how many messages one wake-up will announce individually. A
// mailbox that receives 200 messages at once should produce a summary, not 200
// buzzes.
const maxBatch = 10

// maxPreview bounds how much of the body ends up in the notification, and
// maxFetch how much of each message is pulled from the server to build it: the
// preview needs the first text part, not a 20 MB attachment.
const (
	maxPreview = 300
	maxFetch   = 64 * 1024
)

// bodySection is the fetch item for the preview. Peek, so reading a message
// here does not mark it as seen in the mailbox.
var bodySection = &imap.FetchItemBodySection{
	Peek:    true,
	Partial: &imap.SectionPartial{Offset: 0, Size: maxFetch},
}

type watcher struct {
	server   string
	username string
	password string
	mailbox  string
	tls      *tls.Config

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
		server   = cfg.Required("IMAP_SERVER") // host:993
		username = cfg.Required("IMAP_USERNAME")
		password = cfg.Required("IMAP_PASSWORD")
		mailbox  = cfg.Optional("IMAP_MAILBOX", "INBOX")
		// Office mail servers are routinely reached under a name their
		// certificate does not carry, and signed by a CA nobody outside the
		// company trusts. Verify against the right name and the right CA rather
		// than switching verification off.
		tlsName     = cfg.Optional("IMAP_TLS_SERVER_NAME", "")
		tlsCAFile   = cfg.Optional("IMAP_TLS_CA_FILE", "")
		tlsInsecure = cfg.Bool("IMAP_TLS_INSECURE", false)
		ntfyURL     = cfg.Required("NTFY_URL")
		ntfyToken   = cfg.Required("NTFY_TOKEN_MAIL")
		topic       = cfg.Optional("NTFY_TOPIC_MAIL", "mail")
		hcURL       = cfg.Optional("HC_PING_URL_MAIL", "")
		hcEvery     = cfg.Duration("HC_INTERVAL", 5*time.Minute)
	)
	if err := cfg.Err(); err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	tlsConfig, err := buildTLSConfig(tlsName, tlsCAFile, tlsInsecure)
	if err != nil {
		log.Error("invalid TLS configuration", "error", err)
		os.Exit(1)
	}
	if tlsInsecure {
		log.Warn("IMAP_TLS_INSECURE is set: the server's certificate is not verified")
	}

	w := &watcher{
		server:   server,
		username: username,
		password: password,
		mailbox:  mailbox,
		tls:      tlsConfig,
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

	options.TLSConfig = w.tls
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

	messages, err := c.Fetch(seqSet, &imap.FetchOptions{
		Envelope:    true,
		UID:         true,
		BodySection: []*imap.FetchItemBodySection{bodySection},
	}).Collect()
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
		// Subject as the title, then who it is from and how it starts — enough
		// to decide from the lock screen whether it can wait.
		body := senderLine(m.Envelope)
		if p := preview(m.FindBodySection(bodySection)); p != "" {
			body += "\n\n" + p
		}
		if err := w.ntfy.Publish(ctx, ntfy.Message{
			Topic:    w.topic,
			Title:    subject,
			Message:  body,
			Tags:     []string{"envelope"},
			Priority: 3,
		}); err != nil {
			w.log.Error("publish failed", "subject", subject, "error", err)
		}
	}
	w.log.Info("announced new mail", "count", len(messages))
	return nil
}

// senderLine renders the From header as "Name <addr>", or whichever half exists.
func senderLine(env *imap.Envelope) string {
	addrs := env.From
	if len(addrs) == 0 {
		addrs = env.Sender
	}
	if len(addrs) == 0 {
		return "From: (unknown sender)"
	}
	a := addrs[0]
	name, addr := strings.TrimSpace(a.Name), a.Addr()
	switch {
	case name != "" && addr != "":
		return fmt.Sprintf("From: %s <%s>", name, addr)
	case name != "":
		return "From: " + name
	case addr != "":
		return "From: " + addr
	}
	return "From: (unknown sender)"
}

// preview extracts the first text part of a raw RFC 5322 message and squashes
// it into one short paragraph. Plain text is preferred; HTML-only mail is
// crudely de-tagged. The input may be truncated (see maxFetch), so a parse
// error after some text has been found is not a failure.
func preview(raw []byte) string {
	if len(raw) == 0 {
		return ""
	}
	mr, err := mail.CreateReader(bytes.NewReader(raw))
	if err != nil {
		return ""
	}
	var html string
	for {
		part, err := mr.NextPart()
		if err != nil {
			break
		}
		h, ok := part.Header.(*mail.InlineHeader)
		if !ok {
			continue // attachment
		}
		ctype, _, _ := h.ContentType()
		text, _ := io.ReadAll(io.LimitReader(part.Body, maxFetch))
		switch ctype {
		case "text/plain":
			if s := squash(string(text)); s != "" {
				return s
			}
		case "text/html":
			if html == "" {
				html = string(text)
			}
		}
	}
	return squash(stripTags(html))
}

// squash collapses whitespace and truncates to maxPreview runes.
func squash(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > maxPreview {
		return string(r[:maxPreview]) + "…"
	}
	return s
}

var (
	tagRe    = regexp.MustCompile(`(?is)<(script|style)\b.*?</(script|style)>|<[^>]*>`)
	entityRe = regexp.MustCompile(`&(nbsp|amp|lt|gt|quot|#39);`)
)

func stripTags(s string) string {
	s = tagRe.ReplaceAllString(s, " ")
	return entityRe.ReplaceAllStringFunc(s, func(e string) string {
		switch e {
		case "&nbsp;":
			return " "
		case "&amp;":
			return "&"
		case "&lt;":
			return "<"
		case "&gt;":
			return ">"
		case "&quot;":
			return "\""
		case "&#39;":
			return "'"
		}
		return e
	})
}

// buildTLSConfig returns nil when every option is at its default, so the
// client's own defaults apply untouched.
func buildTLSConfig(serverName, caFile string, insecure bool) (*tls.Config, error) {
	if serverName == "" && caFile == "" && !insecure {
		return nil, nil
	}
	cfg := &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: insecure, //nolint:gosec // explicit, logged opt-in
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("IMAP_TLS_CA_FILE: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("IMAP_TLS_CA_FILE: no certificates found in %s", caFile)
		}
		cfg.RootCAs = pool
	}
	return cfg, nil
}
