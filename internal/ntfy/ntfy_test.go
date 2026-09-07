package ntfy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestPublishSendsJSONWithToken(t *testing.T) {
	var got Message
	var auth, contentType string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		contentType = r.Header.Get("Content-Type")
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "tk_secret", nil)
	msg := Message{
		Topic: "mail", Title: "Ünicode Sender", Message: "Wichtige Nachricht — ✓",
		Click: "https://example.com", Tags: []string{"envelope"}, Priority: 3,
	}
	if err := c.Publish(context.Background(), msg); err != nil {
		t.Fatalf("publish: %v", err)
	}

	if auth != "Bearer tk_secret" {
		t.Errorf("Authorization = %q", auth)
	}
	if contentType != "application/json" {
		t.Errorf("Content-Type = %q", contentType)
	}
	// The JSON API is used precisely so non-ASCII survives; headers would not
	// carry this intact.
	if got.Title != msg.Title || got.Message != msg.Message {
		t.Errorf("round trip lost content: %+v", got)
	}
	if got.Click != msg.Click || got.Topic != "mail" {
		t.Errorf("unexpected payload: %+v", got)
	}
}

func TestPublishRetriesServerErrors(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "", nil)
	c.Attempts = 4
	if err := c.Publish(context.Background(), Message{Topic: "t", Message: "m"}); err != nil {
		t.Fatalf("publish should have succeeded on retry: %v", err)
	}
	if n := calls.Load(); n != 3 {
		t.Fatalf("made %d calls, want 3", n)
	}
}

// A 4xx means the token or topic is wrong. Retrying it just spins, and the
// backoff would delay every subsequent notification behind it.
func TestPublishDoesNotRetryClientErrors(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "bad", nil)
	c.Attempts = 4
	if err := c.Publish(context.Background(), Message{Topic: "t", Message: "m"}); err == nil {
		t.Fatal("expected an error for a 403")
	}
	if n := calls.Load(); n != 1 {
		t.Fatalf("made %d calls, want exactly 1", n)
	}
}

func TestPublishRejectsEmptyTopic(t *testing.T) {
	c := NewClient("http://127.0.0.1:1", "", nil)
	if err := c.Publish(context.Background(), Message{Message: "m"}); err == nil {
		t.Fatal("expected an error for an empty topic")
	}
}

func TestPublishHonoursContextCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	c := NewClient(srv.URL, "", nil)
	c.Attempts = 10
	if err := c.Publish(ctx, Message{Topic: "t", Message: "m"}); err == nil {
		t.Fatal("expected the cancelled context to abort the retry loop")
	}
}
