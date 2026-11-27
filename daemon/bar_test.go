package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
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

// systems points the booted- and current-system links at two store paths, the
// same one unless the running system was switched since boot.
func systems(t *testing.T, b *Bar, booted, current string) {
	t.Helper()
	dir := t.TempDir()
	b.bootedSystem = filepath.Join(dir, "booted-system")
	b.currentSystem = filepath.Join(dir, "current-system")
	if err := os.Symlink(booted, b.bootedSystem); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(current, b.currentSystem); err != nil {
		t.Fatal(err)
	}
}

// An update switched the running system but kept the kiosk session it booted
// with, which on 1.2.0 -> 1.3.x has no bar agent. "bar session not ready" told
// nobody what to do; say that a restart finishes the update.
func TestBarSetAfterUpdateWithoutRebootSaysRestart(t *testing.T) {
	newTestBar(t)
	t.Setenv("DASHBOARD_ASSISTANT_BAR_FIFO", filepath.Join(t.TempDir(), "missing.fifo"))
	b := NewBar()
	systems(t, b, "/nix/store/aaa-nixos-system-1.2.0", "/nix/store/bbb-nixos-system-1.3.1")
	err := b.Set(false)
	if err == nil || !strings.Contains(err.Error(), "restart the device") {
		t.Fatalf("Set after an update without a reboot = %v, want it to say to restart the device", err)
	}
}

// Without an update in between, a missing session is just not up yet (booting,
// or the kiosk restarting): telling the user to restart would be wrong.
func TestBarSetWithoutSessionAndNoUpdateDoesNotSayRestart(t *testing.T) {
	newTestBar(t)
	t.Setenv("DASHBOARD_ASSISTANT_BAR_FIFO", filepath.Join(t.TempDir(), "missing.fifo"))
	b := NewBar()
	systems(t, b, "/nix/store/aaa-nixos-system-1.3.1", "/nix/store/aaa-nixos-system-1.3.1")
	err := b.Set(false)
	if err == nil || strings.Contains(err.Error(), "restart") {
		t.Fatalf("Set with no session and no update = %v, want a plain failure", err)
	}
}
