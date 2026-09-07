// Package logx sets up structured logging for all notification-hub services.
package logx

import (
	"log/slog"
	"os"
	"strings"
)

// Setup installs a process-wide slog handler writing to stderr.
//
// Everything here runs under systemd, which captures stderr into the journal and
// already stamps every line with a timestamp and unit name, so we drop slog's own
// time key to avoid duplicating it.
func Setup(service string) *slog.Logger {
	level := slog.LevelInfo
	if v := os.Getenv("LOG_LEVEL"); v != "" {
		_ = level.UnmarshalText([]byte(strings.ToUpper(v)))
	}

	h := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				return slog.Attr{}
			}
			return a
		},
	})

	l := slog.New(h).With("service", service)
	slog.SetDefault(l)
	return l
}
