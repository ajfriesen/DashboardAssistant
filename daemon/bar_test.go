package main

import (
	"bufio"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// newTestBar points the bar at a temp FIFO (held open read-write, like the
// in-session agent does) and a temp marker, and returns a reader for the
// commands it sends.
func newTestBar(t *testing.T) (*Bar, *bufio.Scanner) {
	t.Helper()
	dir := t.TempDir()
	fifo := filepath.Join(dir, "bar.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })

	old := barHiddenFile
	barHiddenFile = filepath.Join(dir, "bar-hidden")
	t.Cleanup(func() { barHiddenFile = old })
	t.Setenv("DASHBOARD_ASSISTANT_BAR_FIFO", fifo)
	return NewBar(), bufio.NewScanner(f)
}

func TestBarVisibleByDefault(t *testing.T) {
	b, _ := newTestBar(t)
	if !b.Visible() {
		t.Fatal("a device that never hid its bar must show it")
	}
}

// Hiding writes the marker the kiosk's bar launcher reads, before asking the
// session to relaunch the bar, and survives a daemon restart.
func TestBarHideAndShow(t *testing.T) {
	b, sc := newTestBar(t)
	fired := 0
	b.SetObserver(func() { fired++ })

	if err := b.Set(false); err != nil {
		t.Fatalf("Set(false): %v", err)
	}
	expectCmd(t, sc, "restart")
	if _, err := os.Stat(barHiddenFile); err != nil {
		t.Fatalf("marker not written: %v", err)
	}
	if b.Visible() || NewBar().Visible() {
		t.Fatal("bar still visible after hiding it")
	}

	if err := b.Set(true); err != nil {
		t.Fatalf("Set(true): %v", err)
	}
	expectCmd(t, sc, "restart")
	if _, err := os.Stat(barHiddenFile); !os.IsNotExist(err) {
		t.Fatalf("marker still there after showing the bar: %v", err)
	}
	if !b.Visible() {
		t.Fatal("bar hidden after showing it")
	}
	if fired != 2 {
		t.Fatalf("observer fired %d times, want 2", fired)
	}
}

// With no session reading the FIFO, nothing changes: Home Assistant is told
// the command failed and must not see a state the screen does not have.
func TestBarSetWithoutSession(t *testing.T) {
	b, _ := newTestBar(t)
	t.Setenv("DASHBOARD_ASSISTANT_BAR_FIFO", filepath.Join(t.TempDir(), "missing.fifo"))
	b = NewBar()
	if err := b.Set(false); err == nil {
		t.Fatal("Set without a session must fail")
	}
	if !b.Visible() {
		t.Fatal("bar reported hidden although nothing applied it")
	}
	if _, err := os.Stat(barHiddenFile); !os.IsNotExist(err) {
		t.Fatalf("marker written without a session: %v", err)
	}
}
