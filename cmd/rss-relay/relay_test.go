package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"testing"
)

func testRelay() *relay {
	return &relay{
		secret: []byte("test-secret"),
		topic:  "rss",
		log:    slog.Default(),
	}
}

// The signature is the only authentication on the webhook endpoint, so this is
// the security boundary of the whole relay.
func TestValidSignature(t *testing.T) {
	r := testRelay()
	body := []byte(`{"event_type":"new_entries"}`)

	mac := hmac.New(sha256.New, r.secret)
	mac.Write(body)
	good := hex.EncodeToString(mac.Sum(nil))

	if !r.validSignature(good, body) {
		t.Fatal("a correctly signed body was rejected")
	}
	for name, header := range map[string]string{
		"empty":        "",
		"not hex":      "zzzz",
		"wrong digest": hex.EncodeToString(make([]byte, 32)),
		"truncated":    good[:len(good)-2],
	} {
		if r.validSignature(header, body) {
			t.Errorf("%s: signature was accepted but should not be", name)
		}
	}

	// A signature that is valid for a different body must not carry over.
	if r.validSignature(good, []byte(`{"event_type":"tampered"}`)) {
		t.Fatal("signature accepted for a modified body")
	}
}

func TestMessagesFromNewEntries(t *testing.T) {
	r := testRelay()

	var p webhookPayload
	raw := `{
      "event_type": "new_entries",
      "feed": {"id": 1, "title": "Golang Weekly", "site_url": "https://golangweekly.com"},
      "entries": [
        {"id": 10, "title": "Issue 500", "url": "https://example.com/500"},
        {"id": 11, "title": "", "url": "https://example.com/501"}
      ]
    }`
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	msgs := r.messages(p)
	if len(msgs) != 2 {
		t.Fatalf("got %d messages, want 2", len(msgs))
	}

	// Feed name as the title and entry title as the body is what makes the
	// phone's notification shade group by source.
	if msgs[0].Title != "Golang Weekly" {
		t.Errorf("title = %q, want the feed name", msgs[0].Title)
	}
	if msgs[0].Message != "Issue 500" {
		t.Errorf("message = %q, want the entry title", msgs[0].Message)
	}
	if msgs[0].Click != "https://example.com/500" {
		t.Errorf("click = %q, want the entry URL", msgs[0].Click)
	}
	if msgs[0].Topic != "rss" {
		t.Errorf("topic = %q, want rss", msgs[0].Topic)
	}
	if msgs[1].Message != "(untitled entry)" {
		t.Errorf("empty title = %q, want a placeholder", msgs[1].Message)
	}
}

// A per-entry feed title wins over the top-level one: Miniflux sends batches that
// can span feeds.
func TestMessagesPreferPerEntryFeedTitle(t *testing.T) {
	r := testRelay()

	var p webhookPayload
	raw := `{
      "event_type": "new_entries",
      "feed": {"title": "Batch"},
      "entries": [{"title": "Post", "url": "https://e/1", "feed": {"title": "Actual Feed"}}]
    }`
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	msgs := r.messages(p)
	if len(msgs) != 1 || msgs[0].Title != "Actual Feed" {
		t.Fatalf("got %+v, want the per-entry feed title", msgs)
	}
}

func TestMessagesIgnoresUnknownEvents(t *testing.T) {
	r := testRelay()
	var p webhookPayload
	if err := json.Unmarshal([]byte(`{"event_type":"something_else"}`), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msgs := r.messages(p); len(msgs) != 0 {
		t.Fatalf("got %d messages for an unhandled event, want 0", len(msgs))
	}
}
