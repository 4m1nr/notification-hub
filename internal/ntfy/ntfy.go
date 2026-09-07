// Package ntfy publishes notifications to a self-hosted ntfy server.
package ntfy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Message is a single notification.
//
// We publish via ntfy's JSON API rather than its header-based API on purpose: feed
// names, mail subjects and Mattermost messages routinely contain non-ASCII text,
// which HTTP headers cannot carry without mangling.
type Message struct {
	Topic    string   `json:"topic"`
	Title    string   `json:"title,omitempty"`
	Message  string   `json:"message"`
	Click    string   `json:"click,omitempty"`
	Tags     []string `json:"tags,omitempty"`
	Priority int      `json:"priority,omitempty"`
}

// Client publishes messages to one ntfy server using one access token.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
	// Attempts is the total number of tries per publish, including the first.
	Attempts int
	Log      *slog.Logger
}

// NewClient returns a Client with sane defaults for a long-running watcher.
func NewClient(baseURL, token string, log *slog.Logger) *Client {
	return &Client{
		BaseURL:  baseURL,
		Token:    token,
		HTTP:     &http.Client{Timeout: 15 * time.Second},
		Attempts: 4,
		Log:      log,
	}
}

// Publish sends msg, retrying transient failures with exponential backoff.
//
// A watcher that dies because ntfy blipped for two seconds would take its
// dead-man's-switch down with it, so transport errors and 5xx responses are
// retried. A 4xx is a configuration problem (bad token, unknown topic) and fails
// immediately — retrying it would only spin.
func (c *Client) Publish(ctx context.Context, msg Message) error {
	if msg.Topic == "" {
		return errors.New("ntfy: empty topic")
	}
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("ntfy: marshal: %w", err)
	}

	attempts := c.Attempts
	if attempts < 1 {
		attempts = 1
	}

	backoff := 500 * time.Millisecond
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		if attempt > 1 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(backoff):
			}
			backoff *= 2
		}

		lastErr = c.publishOnce(ctx, body)
		if lastErr == nil {
			return nil
		}
		var perm permanentError
		if errors.As(lastErr, &perm) {
			return lastErr
		}
		if c.Log != nil {
			c.Log.Warn("ntfy publish failed, retrying",
				"topic", msg.Topic, "attempt", attempt, "error", lastErr)
		}
	}
	return fmt.Errorf("ntfy: giving up after %d attempts: %w", attempts, lastErr)
}

type permanentError struct{ err error }

func (p permanentError) Error() string { return p.err.Error() }
func (p permanentError) Unwrap() error { return p.err }

func (c *Client) publishOnce(ctx context.Context, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL, bytes.NewReader(body))
	if err != nil {
		return permanentError{err}
	}
	req.Header.Set("Content-Type", "application/json")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}

	snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	err = fmt.Errorf("ntfy: %s: %s", resp.Status, bytes.TrimSpace(snippet))
	if resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != http.StatusTooManyRequests {
		return permanentError{err}
	}
	return err
}
