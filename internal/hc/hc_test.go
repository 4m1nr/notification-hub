package hc

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestDisabledClientIsNoOp(t *testing.T) {
	c := NewClient("", nil)
	if c.Enabled() {
		t.Fatal("an empty URL must not count as enabled")
	}
	if err := c.Ping(context.Background()); err != nil {
		t.Fatalf("ping on a disabled client should be a silent no-op: %v", err)
	}
}

func TestPingStartAndFailUseTheRightPaths(t *testing.T) {
	var path atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path.Store(r.URL.Path)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := NewClient(srv.URL+"/ping/uuid", nil)
	ctx := context.Background()

	for _, tc := range []struct {
		call func(context.Context) error
		want string
	}{
		{c.Ping, "/ping/uuid"},
		{c.Start, "/ping/uuid/start"},
		{c.Fail, "/ping/uuid/fail"},
	} {
		if err := tc.call(ctx); err != nil {
			t.Fatalf("%s: %v", tc.want, err)
		}
		if got := path.Load().(string); got != tc.want {
			t.Errorf("requested %q, want %q", got, tc.want)
		}
	}
}

// The whole point of the heartbeat: when the watched connection is down, we stay
// silent so the check goes red. Pinging regardless would monitor the timer.
func TestHeartbeatWithholdsPingWhenNotAlive(t *testing.T) {
	var pings atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		pings.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	alive := atomic.Bool{}
	h := &Heartbeat{
		Client:   NewClient(srv.URL, nil),
		Interval: 10 * time.Millisecond,
		Alive:    alive.Load,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	h.Run(ctx)

	if n := pings.Load(); n != 0 {
		t.Fatalf("sent %d pings while the connection was down, want 0", n)
	}
}

func TestHeartbeatPingsWhileAlive(t *testing.T) {
	var pings atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		pings.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	h := &Heartbeat{
		Client:   NewClient(srv.URL, nil),
		Interval: 10 * time.Millisecond,
		Alive:    func() bool { return true },
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	h.Run(ctx)

	if n := pings.Load(); n < 2 {
		t.Fatalf("sent %d pings, expected several", n)
	}
}
