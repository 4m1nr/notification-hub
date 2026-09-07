// Package config loads service configuration from the environment, with an
// optional .env file for local development.
//
// In production every process is started by systemd with EnvironmentFile= pointing
// at a 0600 file under /etc/notification-hub, so LoadDotEnv is a convenience for
// running a binary by hand, not the deployment path.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// LoadDotEnv reads KEY=VALUE pairs from path into the environment. Existing
// environment variables always win, so a systemd EnvironmentFile is never
// overridden by a stray .env sitting next to the binary. A missing file is not an
// error.
func LoadDotEnv(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for line := 1; sc.Scan(); line++ {
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		text = strings.TrimPrefix(text, "export ")

		key, val, ok := strings.Cut(text, "=")
		if !ok {
			return fmt.Errorf("%s:%d: missing '='", path, line)
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)

		// Strip a single layer of matching quotes, the way shell sourcing would.
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val)-1] == val[0] {
			val = val[1 : len(val)-1]
		}
		if _, exists := os.LookupEnv(key); !exists {
			if err := os.Setenv(key, val); err != nil {
				return err
			}
		}
	}
	return sc.Err()
}

// A Loader accumulates lookup errors so a misconfigured service reports every
// missing variable at once instead of one per restart.
type Loader struct {
	errs []string
}

func New() *Loader { return &Loader{} }

// Err returns all accumulated errors, or nil.
func (l *Loader) Err() error {
	if len(l.errs) == 0 {
		return nil
	}
	return fmt.Errorf("configuration:\n  - %s", strings.Join(l.errs, "\n  - "))
}

func (l *Loader) fail(format string, args ...any) {
	l.errs = append(l.errs, fmt.Sprintf(format, args...))
}

// Required returns the value of key, recording an error if it is unset or empty.
func (l *Loader) Required(key string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		l.fail("%s is required but not set", key)
	}
	return v
}

// Optional returns the value of key, or def if unset or empty.
func (l *Loader) Optional(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// Int returns key parsed as an integer, or def if unset.
func (l *Loader) Int(key string, def int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		l.fail("%s: %q is not an integer", key, raw)
		return def
	}
	return n
}

// Duration returns key parsed as a Go duration (e.g. "30s", "5m"), or def if unset.
func (l *Loader) Duration(key string, def time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		l.fail("%s: %q is not a duration (try 30s, 5m)", key, raw)
		return def
	}
	return d
}

// Bool returns key parsed as a boolean, or def if unset.
func (l *Loader) Bool(key string, def bool) bool {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		l.fail("%s: %q is not a boolean", key, raw)
		return def
	}
	return b
}

// List returns key split on commas with empty entries dropped, or nil if unset.
func (l *Loader) List(key string) []string {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
