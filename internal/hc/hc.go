// Package hc pings healthchecks.io checks — the dead-man's-switch backstop.
//
// The contract is deliberately inverted from a normal alert: silence is the signal.
// Nothing here ever produces a notification on success; it only keeps a check from
// going red.
package hc

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// Client pings one check URL.
type Client struct {
	// URL is the base ping URL, e.g. https://checks.example.com/ping/<uuid>.
	// An empty URL turns every method into a no-op, so a watcher runs fine before
	// its check has been created.
	URL  string
	HTTP *http.Client
	Log  *slog.Logger
}

func NewClient(url string, log *slog.Logger) *Client {
	return &Client{
		URL:  strings.TrimRight(url, "/"),
		HTTP: &http.Client{Timeout: 10 * time.Second},
		Log:  log,
	}
}

// Enabled reports whether a check URL is configured.
func (c *Client) Enabled() bool { return c != nil && c.URL != "" }

// Ping signals a successful cycle.
func (c *Client) Ping(ctx context.Context) error { return c.send(ctx, "") }

// Start signals the beginning of a run, so healthchecks can measure duration.
func (c *Client) Start(ctx context.Context) error { return c.send(ctx, "/start") }

// Fail signals an explicit failure, taking the check down immediately rather than
// waiting out the grace period.
func (c *Client) Fail(ctx context.Context) error { return c.send(ctx, "/fail") }

func (c *Client) send(ctx context.Context, suffix string) error {
	if !c.Enabled() {
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.URL+suffix, nil)
	if err != nil {
		return err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("healthchecks ping: %s", resp.Status)
	}
	return nil
}

// Heartbeat pings a check on an interval for as long as alive() reports true.
//
// This exists because the watchers are event-driven: a Mattermost channel can be
// legitimately quiet all night, so pinging on message receipt would take the check
// down every evening. Instead we ping on a timer, gated on the connection actually
// being up — which is the thing we want to be alerted about.
type Heartbeat struct {
	Client   *Client
	Interval time.Duration
	// Alive reports whether the thing being monitored is currently healthy. A
	// false result skips the ping, letting the grace period lapse and the alert
	// fire.
	Alive func() bool
	Log   *slog.Logger
}

// Run blocks until ctx is cancelled, pinging on each interval.
func (h *Heartbeat) Run(ctx context.Context) {
	if !h.Client.Enabled() {
		if h.Log != nil {
			h.Log.Warn("no healthchecks URL configured; dead-man's-switch disabled")
		}
		return
	}
	interval := h.Interval
	if interval <= 0 {
		interval = 5 * time.Minute
	}

	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if h.Alive != nil && !h.Alive() {
				if h.Log != nil {
					h.Log.Warn("skipping healthchecks ping: connection is down")
				}
				continue
			}
			if err := h.Client.Ping(ctx); err != nil && h.Log != nil {
				h.Log.Warn("healthchecks ping failed", "error", err)
			}
		}
	}
}
