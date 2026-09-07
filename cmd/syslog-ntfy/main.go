// Command syslog-ntfy is an rsyslog omprog handler: it reads log lines on stdin
// and publishes them to the ntfy "syslog" topic.
//
// omprog starts this once and keeps it alive, feeding it newline-delimited
// messages for as long as rsyslog runs — so this is a read loop, not a one-shot
// filter. stdout belongs to rsyslog's protocol; all diagnostics go to stderr.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/4m1nr/notification-hub/internal/config"
	"github.com/4m1nr/notification-hub/internal/logx"
	"github.com/4m1nr/notification-hub/internal/ntfy"
)

// maxLineBytes bounds a single syslog message. Anything longer is truncated
// rather than dropped.
const maxLineBytes = 64 << 10

func main() {
	log := logx.Setup("syslog-ntfy")

	if exe, err := os.Executable(); err == nil {
		_ = config.LoadDotEnv(filepath.Join(filepath.Dir(exe), ".env"))
	}

	cfg := config.New()
	var (
		ntfyURL   = cfg.Required("NTFY_URL")
		ntfyToken = cfg.Required("NTFY_TOKEN_SYSLOG")
		topic     = cfg.Optional("NTFY_TOPIC_SYSLOG", "syslog")
		window    = cfg.Duration("SYSLOG_DEDUP_WINDOW", time.Minute)
		perMin    = cfg.Int("SYSLOG_MAX_PER_MINUTE", 12)
	)
	if err := cfg.Err(); err != nil {
		log.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	h := &handler{
		topic:    topic,
		client:   ntfy.NewClient(ntfyURL, ntfyToken, log),
		limiter:  newLimiter(window, perMin),
		log:      log,
		hostname: hostname(),
	}

	log.Info("started", "topic", topic, "dedup_window", window, "max_per_minute", perMin)
	h.run(os.Stdin)
	log.Info("stdin closed, exiting")
}

type handler struct {
	topic    string
	client   *ntfy.Client
	limiter  *limiter
	log      *slog.Logger
	hostname string
}

func (h *handler) run(in *os.File) {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 8192), maxLineBytes)

	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}

		verdict := h.limiter.admit(line, time.Now())
		switch verdict.kind {
		case admitSuppressed:
			continue
		case admitThrottled:
			// Say so once per window rather than silently dropping — a burst
			// being hidden is exactly the kind of thing worth knowing about.
			h.publish(ntfy.Message{
				Topic:    h.topic,
				Title:    h.hostname + ": log flood",
				Message:  "Suppressing further syslog alerts for the rest of this minute.",
				Tags:     []string{"warning"},
				Priority: 4,
			})
			continue
		}

		h.publish(ntfy.Message{
			Topic:    h.topic,
			Title:    h.hostname + ": syslog alert",
			Message:  line,
			Tags:     []string{"rotating_light"},
			Priority: 4,
		})
	}
	if err := sc.Err(); err != nil {
		h.log.Error("reading stdin", "error", err)
	}
}

func (h *handler) publish(m ntfy.Message) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := h.client.Publish(ctx, m); err != nil {
		h.log.Error("publish failed", "error", err)
	}
}

type admitKind int

const (
	admitAllowed admitKind = iota
	admitSuppressed
	admitThrottled
)

type admission struct{ kind admitKind }

// limiter keeps one flapping service from burying the phone. It does two things:
// suppresses repeats of an identical message within a window, and caps the total
// number of notifications per minute.
type limiter struct {
	mu          sync.Mutex
	window      time.Duration
	maxPerMin   int
	seen        map[string]time.Time
	minuteStart time.Time
	minuteCount int
	announced   bool
}

func newLimiter(window time.Duration, maxPerMin int) *limiter {
	if maxPerMin < 1 {
		maxPerMin = 1
	}
	return &limiter{
		window:    window,
		maxPerMin: maxPerMin,
		seen:      make(map[string]time.Time),
	}
}

func (l *limiter) admit(line string, now time.Time) admission {
	l.mu.Lock()
	defer l.mu.Unlock()

	if now.Sub(l.minuteStart) >= time.Minute {
		l.minuteStart = now
		l.minuteCount = 0
		l.announced = false
		l.evict(now)
	}

	key := fingerprint(line)
	if last, ok := l.seen[key]; ok && now.Sub(last) < l.window {
		return admission{admitSuppressed}
	}

	if l.minuteCount >= l.maxPerMin {
		if l.announced {
			return admission{admitSuppressed}
		}
		l.announced = true
		return admission{admitThrottled}
	}

	l.seen[key] = now
	l.minuteCount++
	return admission{admitAllowed}
}

// evict drops fingerprints older than the dedup window so the map cannot grow
// without bound over a long uptime.
func (l *limiter) evict(now time.Time) {
	for k, t := range l.seen {
		if now.Sub(t) >= l.window {
			delete(l.seen, k)
		}
	}
}

// fingerprint identifies "the same message again". Digits are collapsed so that
// otherwise-identical lines differing only by a PID, timestamp or byte count are
// treated as repeats.
func fingerprint(line string) string {
	var b strings.Builder
	b.Grow(len(line))
	prevDigit := false
	for _, r := range line {
		if r >= '0' && r <= '9' {
			if !prevDigit {
				b.WriteByte('#')
			}
			prevDigit = true
			continue
		}
		prevDigit = false
		b.WriteRune(r)
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:8])
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "vps"
	}
	return h
}
