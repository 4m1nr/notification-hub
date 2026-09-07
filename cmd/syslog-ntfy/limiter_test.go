package main

import (
	"testing"
	"time"
)

func TestLimiterSuppressesRepeats(t *testing.T) {
	l := newLimiter(time.Minute, 100)
	now := time.Now()

	line := "web01 err/daemon nginx[123]: upstream timed out"
	if got := l.admit(line, now).kind; got != admitAllowed {
		t.Fatalf("first occurrence: got %v, want admitAllowed", got)
	}
	if got := l.admit(line, now.Add(10*time.Second)).kind; got != admitSuppressed {
		t.Fatalf("repeat inside window: got %v, want admitSuppressed", got)
	}
	if got := l.admit(line, now.Add(90*time.Second)).kind; got != admitAllowed {
		t.Fatalf("repeat after window: got %v, want admitAllowed", got)
	}
}

// A flapping service logs the same failure with a different PID every time. Those
// are the same event as far as a phone notification is concerned.
func TestFingerprintIgnoresVaryingNumbers(t *testing.T) {
	a := "web01 err/daemon nginx[123]: connect() failed after 30 ms"
	b := "web01 err/daemon nginx[98765]: connect() failed after 4 ms"
	if fingerprint(a) != fingerprint(b) {
		t.Fatalf("expected %q and %q to share a fingerprint", a, b)
	}

	c := "web01 err/daemon nginx: disk full"
	if fingerprint(a) == fingerprint(c) {
		t.Fatal("genuinely different messages must not collide")
	}
}

func TestLimiterCapsPerMinute(t *testing.T) {
	const cap = 3
	l := newLimiter(time.Millisecond, cap)
	now := time.Now()

	for i := range cap {
		line := "unique message " + string(rune('a'+i))
		if got := l.admit(line, now).kind; got != admitAllowed {
			t.Fatalf("message %d: got %v, want admitAllowed", i, got)
		}
	}

	// The cap is reached: the next distinct message announces the throttle once,
	// then everything after it is silent until the minute rolls over.
	if got := l.admit("overflow one", now).kind; got != admitThrottled {
		t.Fatalf("first over cap: got %v, want admitThrottled", got)
	}
	if got := l.admit("overflow two", now).kind; got != admitSuppressed {
		t.Fatalf("second over cap: got %v, want admitSuppressed", got)
	}

	if got := l.admit("overflow three", now.Add(61*time.Second)).kind; got != admitAllowed {
		t.Fatalf("after the minute rolled over: got %v, want admitAllowed", got)
	}
}

// The dedup map must not grow forever in a process that runs for months.
func TestLimiterEvictsOldFingerprints(t *testing.T) {
	l := newLimiter(time.Second, 1000)
	now := time.Now()

	for i := range 50 {
		l.admit("message "+string(rune('a'+i%26))+string(rune('a'+i/26)), now)
	}
	if len(l.seen) == 0 {
		t.Fatal("expected fingerprints to be recorded")
	}

	// Crossing a minute boundary triggers eviction of anything older than the
	// dedup window.
	l.admit("trigger", now.Add(61*time.Second))
	if len(l.seen) > 1 {
		t.Fatalf("expected stale fingerprints to be evicted, %d remain", len(l.seen))
	}
}
