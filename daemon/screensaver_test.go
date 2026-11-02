package main

import (
	"bufio"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// newTestScreensaver points the saver at a temp FIFO (held open read-write, like
// the in-session agent does) and a temp prefs file, and returns a reader for the
// commands it sends.
func newTestScreensaver(t *testing.T) (*Screensaver, *bufio.Scanner) {
	t.Helper()
	dir := t.TempDir()
	fifo := filepath.Join(dir, "screensaver.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })

	old := screensaverFile
	screensaverFile = filepath.Join(dir, "screensaver.json")
	t.Cleanup(func() { screensaverFile = old })
	t.Setenv("DASHBOARD_ASSISTANT_SCREENSAVER_FIFO", fifo)
	return NewScreensaver(), bufio.NewScanner(f)
}

func expectCmd(t *testing.T, sc *bufio.Scanner, want string) {
	t.Helper()
	if !sc.Scan() || sc.Text() != want {
		t.Fatalf("command = %q, want %q", sc.Text(), want)
	}
}

func TestScreensaverDefaults(t *testing.T) {
	s, _ := newTestScreensaver(t)
	if s.Name() != "clock" || s.Timeout() != 10 {
		t.Fatalf("defaults = %q/%d, want clock/10", s.Name(), s.Timeout())
	}
	// Turning it off must survive a restart, not fall back to the default.
	s.SetTimeout(0)
	if p := loadScreensaverPrefs(); p.Timeout != 0 {
		t.Fatalf("persisted timeout = %d, want 0", p.Timeout)
	}
}

func TestScreensaverIdleStartsAndTouchStops(t *testing.T) {
	s, sc := newTestScreensaver(t)
	s.SetTimeout(1)
	s.armed = time.Now().Add(-2 * time.Minute)

	s.Tick(30, true) // touched 30s ago: not idle long enough
	if s.Active() {
		t.Fatal("started before the timeout")
	}
	s.Tick(61, false) // idle, but not eligible (panel off / not READY)
	if s.Active() {
		t.Fatal("started while ineligible")
	}
	s.Tick(61, true)
	if !s.Active() {
		t.Fatal("did not start after the timeout")
	}
	expectCmd(t, sc, "start clock")

	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "stop")
	// A manual stop re-arms the timer, so the next tick doesn't put it straight back.
	s.Tick(600, true)
	if s.Active() {
		t.Fatal("restarted right after a stop")
	}
}

func TestScreensaverPrefsPersistAndValidate(t *testing.T) {
	s, _ := newTestScreensaver(t)
	if err := s.SetName("nope"); err == nil {
		t.Fatal("accepted an unknown screen saver")
	}
	s.SetTimeout(9999)
	if s.Timeout() != screensaverMaxTimeout {
		t.Fatalf("timeout = %d, want clamped to %d", s.Timeout(), screensaverMaxTimeout)
	}
	if p := loadScreensaverPrefs(); p.Timeout != screensaverMaxTimeout || p.Name != "clock" {
		t.Fatalf("persisted = %+v", p)
	}
}
