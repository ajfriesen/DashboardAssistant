package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"slices"
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

// A restarted daemon starts inactive, so Reset must still send "stop": a saver
// left over in the running session would otherwise never be taken down.
func TestScreensaverResetStopsLeftoverSaver(t *testing.T) {
	s, sc := newTestScreensaver(t)
	s.Reset()
	expectCmd(t, sc, "stop")
	if s.Active() {
		t.Fatal("active after Reset")
	}
}

// With no session reading the FIFO (boot), Reset must not block or panic.
func TestScreensaverResetWithoutSession(t *testing.T) {
	t.Setenv("DASHBOARD_ASSISTANT_SCREENSAVER_FIFO", filepath.Join(t.TempDir(), "missing.fifo"))
	NewScreensaver().Reset()
}

// fakeDimmer records what the screen saver asks of the display.
type fakeDimmer struct{ calls []string }

func (f *fakeDimmer) Dim(pct int) error {
	f.calls = append(f.calls, fmt.Sprintf("dim %d", pct))
	return nil
}
func (f *fakeDimmer) Undim() error { f.calls = append(f.calls, "undim"); return nil }

func expectDims(t *testing.T, f *fakeDimmer, want ...string) {
	t.Helper()
	if !slices.Equal(f.calls, want) {
		t.Fatalf("dimmer got %q, want %q", f.calls, want)
	}
	f.calls = nil
}

// Off by default, so a device updated from a release without it keeps the
// brightness it had while the saver shows.
func TestScreensaverBrightnessOffByDefault(t *testing.T) {
	s, sc := newTestScreensaver(t)
	d := &fakeDimmer{}
	s.SetDimmer(d)
	if s.Brightness() != 0 {
		t.Fatalf("brightness = %d, want 0 (off)", s.Brightness())
	}
	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "start clock")
	expectDims(t, d)
}

func TestScreensaverDimsWhileShowing(t *testing.T) {
	s, sc := newTestScreensaver(t)
	d := &fakeDimmer{}
	s.SetDimmer(d)
	s.SetBrightness(15)

	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "start clock")
	expectDims(t, d, "dim 15")

	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "stop")
	expectDims(t, d, "undim")

	// Stop runs on every touch; with no saver up it must leave the display alone.
	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	expectDims(t, d)
}

// Changing the level while the saver shows applies it at once, and turning it
// off brings the normal brightness back.
func TestScreensaverBrightnessChangeWhileShowing(t *testing.T) {
	s, sc := newTestScreensaver(t)
	d := &fakeDimmer{}
	s.SetDimmer(d)
	if err := s.Start(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "start clock")

	s.SetBrightness(30)
	expectDims(t, d, "dim 30")
	s.SetBrightness(0)
	expectDims(t, d, "undim")

	if err := s.Stop(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "stop")
	expectDims(t, d, "undim")

	// Not showing: only remembered for next time.
	s.SetBrightness(20)
	expectDims(t, d)
}

func TestScreensaverBrightnessPersistsAndClamps(t *testing.T) {
	s, _ := newTestScreensaver(t)
	s.SetBrightness(250)
	if s.Brightness() != 100 {
		t.Fatalf("brightness = %d, want clamped to 100", s.Brightness())
	}
	s.SetBrightness(-5)
	if s.Brightness() != 0 {
		t.Fatalf("brightness = %d, want clamped to 0", s.Brightness())
	}
	s.SetBrightness(12)
	if p := loadScreensaverPrefs(); p.Brightness != 12 || p.Name != "clock" || p.Timeout != 10 {
		t.Fatalf("persisted = %+v", p)
	}
}

// A saver gone without a stop (daemon or session restart) may have left the
// display dimmed, so both paths ask for the normal brightness back.
func TestScreensaverResetAndReportOffUndim(t *testing.T) {
	s, sc := newTestScreensaver(t)
	d := &fakeDimmer{}
	s.SetDimmer(d)
	s.Reset()
	expectCmd(t, sc, "stop")
	expectDims(t, d, "undim")
	s.ReportOff()
	expectDims(t, d, "undim")
}
