package main

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"syscall"
)

// Bar shows or hides the kiosk's bottom button bar (the HA "Button bar"
// switch). Hidden is a marker file the kiosk's bar launcher checks: every bar
// launch (session start, rotation, a dismissed screen saver) goes through that
// one script, so the choice holds across all of them and across reboots. To
// apply a change now, the daemon writes "restart" to a FIFO and an agent in the
// Sway session re-runs the launcher, like the rotation agent does.
type Bar struct {
	mu       sync.Mutex
	visible  bool
	fifo     string
	observer func()
}

// NewBar reads the marker (no marker: visible). The FIFO path can be
// overridden for testing off-device.
func NewBar() *Bar {
	fifo := barFifo
	if v := os.Getenv("DASHBOARD_ASSISTANT_BAR_FIFO"); v != "" {
		fifo = v
	}
	_, err := os.Stat(barHiddenFile)
	return &Bar{visible: err != nil, fifo: fifo}
}

// SetObserver registers a callback fired (outside the lock) after any change, so
// the HA hub can broadcast it.
func (b *Bar) SetObserver(f func()) {
	b.mu.Lock()
	b.observer = f
	b.mu.Unlock()
}

// Visible reports whether the bar is shown.
func (b *Bar) Visible() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.visible
}

// Set shows or hides the bar. The FIFO is opened first, so with no session up
// to apply it nothing changes and the caller gets an error, like Rotation. The
// marker is written before the agent is poked, because the launcher it runs
// reads it.
func (b *Bar) Set(visible bool) error {
	b.mu.Lock()
	// O_NONBLOCK so opening a reader-less FIFO fails with ENXIO instead of blocking.
	f, err := os.OpenFile(b.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		b.mu.Unlock()
		return fmt.Errorf("bar session not ready: %w", err)
	}
	defer f.Close()
	if err := saveBarHidden(!visible); err != nil {
		b.mu.Unlock()
		return err
	}
	if _, err := f.WriteString("restart\n"); err != nil {
		b.mu.Unlock()
		return fmt.Errorf("write bar fifo: %w", err)
	}
	b.visible = visible
	obs := b.observer
	b.mu.Unlock()

	if obs != nil {
		obs()
	}
	return nil
}

// saveBarHidden creates or removes the marker. Mode 0664: readable by the
// shared `dashboard` group, which the kiosk's bar launcher runs in.
func saveBarHidden(hidden bool) error {
	if hidden {
		if err := os.WriteFile(barHiddenFile, nil, 0o664); err != nil {
			return fmt.Errorf("hide bar: %w", err)
		}
		return nil
	}
	if err := os.Remove(barHiddenFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("show bar: %w", err)
	}
	return nil
}
