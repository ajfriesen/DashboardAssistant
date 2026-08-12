package main

import (
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/godbus/dbus/v5"
)

// Sendspin exposes the device's multi-room audio player (see
// modules/core/sendspin.nix) to Home Assistant as a switch. Unlike the other
// capability objects there is no in-session agent to talk to: the player is a
// plain system service, so ON/OFF is StartUnit/StopUnit over systemd's D-Bus
// API — the same route power.go takes to logind, allowed for this one unit by a
// scoped polkit rule.
//
// The desired state is persisted here rather than in systemd's own
// enabled/disabled bit, because the image's root is rebuilt from the store on
// every boot: `systemctl enable` would not survive it. sendspin-player.service
// is deliberately not wanted by multi-user.target, and Reconcile applies the
// persisted state once at daemon start.
//
// Available reports whether the player is part of this build at all. When it is
// not, the snapshot omits the whole section and the integration creates no
// entity.
type Sendspin struct {
	mu        sync.Mutex
	available bool
	on        bool
	observer  func()
}

// sendspinUnit is the systemd unit this controls; it must match the scoped
// polkit rule in modules/core/sendspin.nix, which grants exactly this name.
const sendspinUnit = "sendspin-player.service"

// NewSendspin loads the persisted on/off choice (default on, matching the Nix
// module's "a device with speakers should just work" default). Availability
// comes from the environment variable the module sets on the daemon's unit, so
// a build without the player never advertises the capability.
func NewSendspin() *Sendspin {
	return &Sendspin{
		available: os.Getenv("DASHBOARD_ASSISTANT_SENDSPIN") == "1",
		on:        loadSendspin(),
	}
}

// SetObserver registers a callback fired (outside the lock) after any change, so
// the HA hub can broadcast the state.
func (s *Sendspin) SetObserver(f func()) {
	s.mu.Lock()
	s.observer = f
	s.mu.Unlock()
}

// Available reports whether this build ships the Sendspin player.
func (s *Sendspin) Available() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.available
}

// On reports the desired state — what the switch shows. Actual reports what
// systemd is doing; the two only differ while the unit is starting or after it
// has failed.
func (s *Sendspin) On() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.on
}

// Set starts or stops the player and persists the choice. The persist happens
// even if systemd refuses, so a transient D-Bus failure doesn't silently revert
// the user's intent on the next boot; the error still propagates to the caller.
func (s *Sendspin) Set(on bool) error {
	if !s.Available() {
		return fmt.Errorf("sendspin player not available on this device")
	}

	if err := setUnitActive(sendspinUnit, on); err != nil {
		return err
	}

	s.mu.Lock()
	s.on = on
	obs := s.observer
	s.mu.Unlock()

	saveSendspin(on)

	if obs != nil {
		obs()
	}
	return nil
}

// Reconcile applies the persisted state at daemon start. The unit has no
// install target of its own, so without this a device that was left ON would
// come back silent. Errors are logged, not fatal: the daemon's other duties
// (kiosk, HA API) must not depend on the sound card.
func (s *Sendspin) Reconcile() {
	if !s.Available() {
		return
	}
	if err := setUnitActive(sendspinUnit, s.On()); err != nil {
		fmt.Fprintf(os.Stderr, "sendspin: reconcile: %v\n", err)
	}
}

// Actual reports the unit's live ActiveState ("active", "inactive", "failed",
// "activating"), or "" when it can't be read. Surfaced to HA as an attribute so
// a player that is switched on but crash-looping is visible as such rather than
// showing a happy ON.
func (s *Sendspin) Actual() string {
	if !s.Available() {
		return ""
	}
	state, err := unitActiveState(sendspinUnit)
	if err != nil {
		return ""
	}
	return state
}

// setUnitActive starts or stops a systemd unit over the system bus. "replace"
// is systemd's standard job mode: supersede any queued job for the unit rather
// than failing or stacking up, which matters when HA toggles the switch twice
// in quick succession.
func setUnitActive(unit string, on bool) error {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("connect system bus: %w", err)
	}
	defer conn.Close()

	method := "StopUnit"
	if on {
		method = "StartUnit"
	}
	obj := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	call := obj.Call("org.freedesktop.systemd1.Manager."+method, 0, unit, "replace")
	if call.Err != nil {
		return fmt.Errorf("systemd %s %s: %w", method, unit, call.Err)
	}
	return nil
}

// unitActiveState reads a unit's ActiveState property. Reading properties needs
// no polkit grant (only job control does), so this works even where Set would
// be denied.
func unitActiveState(unit string) (string, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return "", fmt.Errorf("connect system bus: %w", err)
	}
	defer conn.Close()

	mgr := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	var path dbus.ObjectPath
	if err := mgr.Call("org.freedesktop.systemd1.Manager.GetUnit", 0, unit).Store(&path); err != nil {
		return "", fmt.Errorf("get unit %s: %w", unit, err)
	}

	prop, err := conn.Object("org.freedesktop.systemd1", path).GetProperty("org.freedesktop.systemd1.Unit.ActiveState")
	if err != nil {
		return "", fmt.Errorf("read ActiveState %s: %w", unit, err)
	}
	state, ok := prop.Value().(string)
	if !ok {
		return "", fmt.Errorf("ActiveState %s: unexpected type %T", unit, prop.Value())
	}
	return state, nil
}

// loadSendspin reads the persisted choice, defaulting to on for a missing or
// unrecognised file — a fresh device should show up in Music Assistant without
// anyone touching a switch first.
func loadSendspin() bool {
	b, err := os.ReadFile(sendspinFile)
	if err != nil {
		return true
	}
	return strings.TrimSpace(string(b)) != "off"
}

// saveSendspin atomically persists the choice. Mode 0664 and best-effort, like
// saveTheme: not secret, and a failed save must not fail the command that
// already took effect.
func saveSendspin(on bool) {
	mode := "off"
	if on {
		mode = "on"
	}
	tmp := sendspinFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(mode+"\n"), 0o664); err != nil {
		fmt.Fprintf(os.Stderr, "sendspin: save %s: %v\n", sendspinFile, err)
		return
	}
	if err := os.Rename(tmp, sendspinFile); err != nil {
		fmt.Fprintf(os.Stderr, "sendspin: save %s: %v\n", sendspinFile, err)
	}
}
