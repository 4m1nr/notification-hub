package main

import (
	"encoding/json"
	"log/slog"
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
)

func testWatcher(mods func(*watcher)) *watcher {
	w := &watcher{
		serverURL:      "https://mm.example.com",
		notifyMentions: true,
		notifyDMs:      true,
		topic:          "mattermost",
		me:             &model.User{Id: "me123", Username: "amin"},
		log:            slog.Default(),
	}
	if mods != nil {
		mods(w)
	}
	return w
}

func postedEvent(t *testing.T, post *model.Post, data map[string]any) *model.WebSocketEvent {
	t.Helper()
	raw, err := json.Marshal(post)
	if err != nil {
		t.Fatalf("marshal post: %v", err)
	}
	if data == nil {
		data = map[string]any{}
	}
	data["post"] = string(raw)

	ev := model.NewWebSocketEvent(model.WebsocketEventPosted, "", "", "", nil, "")
	return ev.SetData(data)
}

// Without this filter, every message sent from the desktop client buzzes the
// phone in your pocket.
func TestOwnMessagesAreIgnored(t *testing.T) {
	w := testWatcher(nil)
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "me123", Message: "@amin hello"}, map[string]any{
		"mentions": `["me123"]`,
	})
	if _, want := w.evaluate(ev); want {
		t.Fatal("a post from the watching user must not notify")
	}
}

func TestSystemMessagesAreIgnored(t *testing.T) {
	w := testWatcher(nil)
	ev := postedEvent(t, &model.Post{
		Id: "p1", UserId: "other", Type: "system_join_channel", Message: "joined",
	}, map[string]any{"mentions": `["me123"]`})
	if _, want := w.evaluate(ev); want {
		t.Fatal("system join/leave messages must not notify")
	}
}

func TestMentionNotifiesWithHigherPriority(t *testing.T) {
	w := testWatcher(nil)
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: "@amin can you look?"},
		map[string]any{
			"mentions":             `["me123"]`,
			"channel_name":         "town-square",
			"channel_display_name": "Town Square",
			"channel_type":         string(model.ChannelTypeOpen),
			"sender_name":          "@colleague",
		})

	msg, want := w.evaluate(ev)
	if !want {
		t.Fatal("a mention should notify")
	}
	if msg.Priority != 4 {
		t.Errorf("priority = %d, want 4 for a mention", msg.Priority)
	}
	if msg.Title != "@colleague · Town Square" {
		t.Errorf("title = %q", msg.Title)
	}
	if msg.Click != "https://mm.example.com/_redirect/pl/p1" {
		t.Errorf("click = %q, want a permalink", msg.Click)
	}
}

// A post in a busy channel that does not mention us and is not on the allowlist
// is exactly the noise this watcher exists to avoid.
func TestUnrelatedChannelPostIsIgnored(t *testing.T) {
	w := testWatcher(nil)
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: "lunch?"},
		map[string]any{
			"mentions":     `[]`,
			"channel_name": "random",
			"channel_type": string(model.ChannelTypeOpen),
			"sender_name":  "@colleague",
		})
	if _, want := w.evaluate(ev); want {
		t.Fatal("an unrelated channel post must not notify")
	}
}

func TestAllowlistedChannelNotifies(t *testing.T) {
	w := testWatcher(func(w *watcher) {
		w.notifyMentions = false
		w.notifyDMs = false
		w.channels = map[string]bool{"incidents": true}
	})
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: "prod is down"},
		map[string]any{
			"mentions":             `[]`,
			"channel_name":         "incidents",
			"channel_display_name": "Incidents",
			"channel_type":         string(model.ChannelTypeOpen),
			"sender_name":          "@oncall",
		})
	msg, want := w.evaluate(ev)
	if !want {
		t.Fatal("an allowlisted channel should notify")
	}
	if msg.Priority != 3 {
		t.Errorf("priority = %d, want 3 for a plain channel match", msg.Priority)
	}
}

func TestDirectMessageNotifies(t *testing.T) {
	w := testWatcher(nil)
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: "ping"},
		map[string]any{
			"mentions":     `[]`,
			"channel_name": "me123__other",
			"channel_type": string(model.ChannelTypeDirect),
			"sender_name":  "@colleague",
		})
	msg, want := w.evaluate(ev)
	if !want {
		t.Fatal("a direct message should notify")
	}
	// The generated DM channel name is meaningless to a human.
	if msg.Title != "@colleague · Direct message" {
		t.Errorf("title = %q", msg.Title)
	}
}

// Some server versions omit the "mentions" field entirely.
func TestMentionFallsBackToTextMatch(t *testing.T) {
	w := testWatcher(func(w *watcher) { w.notifyDMs = false })
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: "hey @Amin look at this"},
		map[string]any{
			"channel_name": "random",
			"channel_type": string(model.ChannelTypeOpen),
			"sender_name":  "@colleague",
		})
	if _, want := w.evaluate(ev); !want {
		t.Fatal("expected the @username fallback to detect the mention")
	}
}

func TestLongMessagesAreTruncated(t *testing.T) {
	w := testWatcher(nil)
	long := make([]byte, maxPreview+200)
	for i := range long {
		long[i] = 'x'
	}
	ev := postedEvent(t, &model.Post{Id: "p1", UserId: "other", Message: string(long)},
		map[string]any{
			"mentions":     `["me123"]`,
			"channel_name": "random",
			"channel_type": string(model.ChannelTypeOpen),
			"sender_name":  "@colleague",
		})
	msg, want := w.evaluate(ev)
	if !want {
		t.Fatal("expected a notification")
	}
	if len([]rune(msg.Message)) > maxPreview+1 {
		t.Fatalf("message not truncated: %d runes", len([]rune(msg.Message)))
	}
}

func TestToWebSocketURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://mm.example.com": "wss://mm.example.com",
		"http://localhost:8065":  "ws://localhost:8065",
		"wss://already":          "wss://already",
	} {
		if got := toWebSocketURL(in); got != want {
			t.Errorf("toWebSocketURL(%q) = %q, want %q", in, got, want)
		}
	}
}
