package main

import (
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// Selectable display rotations, in degrees clockwise. 0 is the panel's native
// orientation. Only these four discrete angles are meaningful, so HA exposes
// rotation as a select entity (a dropdown), not a slider like Zoom.
var rotationOptions = []int{0, 90, 180, 270}

const rotationDefault = 0

// Rotation controls the physical display orientation. Like Zoom it can't reach
// the compositor directly — Sway's IPC socket lives under the kiosk user's 0700
// runtime dir — so it writes "rotate <deg>" to a FIFO in the shared state dir and
// an agent inside the Sway session applies it via `swaymsg output * transform`.
// The angle is persisted so it survives a reboot (the compositor always comes up
// at 0°), and an observer is notified after any change so the HA hub broadcasts it.
type Rotation struct {
	mu       sync.Mutex
	deg      int
	fifo     string
	observer func()
}

// NewRotation loads the persisted angle (default 0°). The FIFO path can be
// overridden for testing off-device.
func NewRotation() *Rotation {
	fifo := rotationFifo
	if v := os.Getenv("DASHBOARD_ASSISTANT_ROTATION_FIFO"); v != "" {
		fifo = v
	}
	return &Rotation{deg: loadRotation(), fifo: fifo}
}

// SetObserver registers a callback fired (outside the lock) after any change, so
// the HA hub can broadcast the angle.
func (r *Rotation) SetObserver(f func()) {
	r.mu.Lock()
	r.observer = f
	r.mu.Unlock()
}

// Degrees reports the last requested rotation, in degrees clockwise.
func (r *Rotation) Degrees() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.deg
}

// Options returns the selectable angles, for the HA select entity.
func (r *Rotation) Options() []int { return rotationOptions }

// Set requests an absolute rotation (one of rotationOptions), persists it, and
// drives the in-session agent over the FIFO. An unsupported angle is rejected so
// the compositor is never handed an invalid transform. Writing is non-blocking:
// if the kiosk session isn't up there's no reader, and we report that rather than
// hang the caller (an API command handler) — the persisted value is still
// restored on next launch.
func (r *Rotation) Set(deg int) error {
	if !validRotation(deg) {
		return fmt.Errorf("unsupported rotation %d; want one of %v", deg, rotationOptions)
	}
	r.mu.Lock()
	if err := r.writeCmd("rotate " + strconv.Itoa(deg)); err != nil {
		r.mu.Unlock()
		return err
	}
	r.deg = deg
	obs := r.observer
	r.mu.Unlock()

	// Persist outside the lock; a failed save is non-fatal (the angle still
	// applied), so log-and-continue in saveRotation rather than fail the command.
	saveRotation(deg)

	if obs != nil {
		obs()
	}
	return nil
}

// writeCmd sends one command line to the in-session agent over the FIFO.
// O_NONBLOCK so opening a reader-less FIFO fails with ENXIO instead of blocking.
func (r *Rotation) writeCmd(line string) error {
	f, err := os.OpenFile(r.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("rotation session not ready: %w", err)
	}
	_, werr := f.WriteString(line + "\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write rotation fifo: %w", werr)
	}
	return nil
}

// validRotation reports whether deg is one of the supported angles.
func validRotation(deg int) bool {
	return slices.Contains(rotationOptions, deg)
}

// loadRotation reads the persisted angle, falling back to the default on a
// missing, unparseable, or unsupported file — a bad file can't wedge the display
// at an invalid transform.
func loadRotation() int {
	b, err := os.ReadFile(rotationFile)
	if err != nil {
		return rotationDefault
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || !validRotation(n) {
		return rotationDefault
	}
	return n
}

// saveRotation atomically persists the angle. Mode 0664: readable by the shared
// `dashboard` group (the kiosk restores it on launch), like the zoom level — the
// orientation isn't secret. Best-effort: a save error is logged, not returned.
func saveRotation(deg int) {
	tmp := rotationFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(deg)+"\n"), 0o664); err != nil {
		fmt.Fprintf(os.Stderr, "rotation: save %s: %v\n", rotationFile, err)
		return
	}
	if err := os.Rename(tmp, rotationFile); err != nil {
		fmt.Fprintf(os.Stderr, "rotation: save %s: %v\n", rotationFile, err)
	}
}
