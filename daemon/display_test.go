package main

import (
	"bufio"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func newTestDisplay(t *testing.T) (*Display, *bufio.Scanner) {
	t.Helper()
	fifo := filepath.Join(t.TempDir(), "display.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	t.Setenv("DASHBOARD_ASSISTANT_DISPLAY_FIFO", fifo)
	return NewDisplay(), bufio.NewScanner(f)
}

// Dimming for the screen saver is not a brightness change: the level HA shows
// (and the one the panel returns to) stays put.
func TestDisplayDimLeavesTheBrightnessAlone(t *testing.T) {
	d, sc := newTestDisplay(t)
	if err := d.SetBrightness(70); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "bright 70")

	fired := 0
	d.SetObserver(func() { fired++ })
	if err := d.Dim(10); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "dim 10")
	if err := d.Undim(); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "undim")
	if d.Brightness() != 70 || fired != 0 {
		t.Fatalf("brightness = %d, observer fired %d times; want 70 and 0", d.Brightness(), fired)
	}
}
