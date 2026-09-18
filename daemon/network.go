package main

import (
	"fmt"
	"log"
	"sync"

	"github.com/godbus/dbus/v5"
)

// NetworkManager D-Bus constants.
const (
	nmService     = "org.freedesktop.NetworkManager"
	nmPath        = "/org/freedesktop/NetworkManager"
	nmIface       = "org.freedesktop.NetworkManager"
	nmDevIface    = "org.freedesktop.NetworkManager.Device"
	nmActiveConn  = "org.freedesktop.NetworkManager.Connection.Active"
	nmSettingsPth = "/org/freedesktop/NetworkManager/Settings"
	nmSettings    = "org.freedesktop.NetworkManager.Settings"
	nmSettingsCon = "org.freedesktop.NetworkManager.Settings.Connection"

	// NMDeviceType.WIFI
	nmDeviceTypeWifi uint32 = 2
	// NMActiveConnectionState.ACTIVATED
	nmActiveStateActivated uint32 = 2
)

// NetworkManager wraps the system-bus connection and the Wi-Fi device path.
type NetworkManager struct {
	conn *dbus.Conn

	// Resolved lazily, and re-resolved for as long as we do not have one. It
	// cannot be looked up once at startup: NetworkManager registers devices
	// asynchronously, and this daemon routinely wins that race — it is ordered
	// after dbus.service and network.target, neither of which waits for a radio
	// to be probed and its supplicant attached. Caching the empty result left
	// Wi-Fi dead for the whole boot, which broke seed-file provisioning exactly
	// as badly as it would break any other use of the radio.
	mu      sync.Mutex
	wifiDev dbus.ObjectPath
}

// NewNetworkManager connects to the system bus and locates the first Wi-Fi device.
func NewNetworkManager() (*NetworkManager, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("connect system bus: %w", err)
	}
	nm := &NetworkManager{conn: conn}
	// A Wi-Fi device is optional: wired-only hosts (e.g. QEMU) still get a working
	// D-Bus layer for connection detection and config-only provisioning. Not
	// finding one here is not final — see wifiDevice.
	nm.wifiDevice()
	return nm, nil
}

// wifiDevice returns the Wi-Fi device path, looking it up again whenever we do
// not have one yet. "" on a host with no wireless hardware.
func (nm *NetworkManager) wifiDevice() dbus.ObjectPath {
	nm.mu.Lock()
	defer nm.mu.Unlock()
	if nm.wifiDev != "" {
		return nm.wifiDev
	}
	if dev, err := nm.findWifiDevice(); err == nil {
		nm.wifiDev = dev
	}
	return nm.wifiDev
}

func (nm *NetworkManager) Close() error { return nm.conn.Close() }

func (nm *NetworkManager) findWifiDevice() (dbus.ObjectPath, error) {
	obj := nm.conn.Object(nmService, nmPath)
	var devices []dbus.ObjectPath
	if err := obj.Call(nmIface+".GetDevices", 0).Store(&devices); err != nil {
		return "", fmt.Errorf("GetDevices: %w", err)
	}
	for _, d := range devices {
		devObj := nm.conn.Object(nmService, d)
		v, err := devObj.GetProperty(nmDevIface + ".DeviceType")
		if err != nil {
			continue
		}
		if t, ok := v.Value().(uint32); ok && t == nmDeviceTypeWifi {
			return d, nil
		}
	}
	return "", fmt.Errorf("no Wi-Fi device found")
}

// NetStatus describes the currently active primary connection, if any.
type NetStatus struct {
	Connected bool   `json:"connected"`
	Type      string `json:"type"` // "ethernet", "wifi", or the raw NM type
	Name      string `json:"name"` // connection id, e.g. "Wired connection 1"
}

// NetInfo returns the active primary connection. It keys off an *activated*
// active connection rather than NM's Connectivity property, which requires a
// connectivity-check URI that is often disabled on minimal NixOS.
//
// Hotspot-style connections are skipped: an AP-mode or ipv4 method=shared
// connection is itself an ACTIVATED active connection, so without this a device
// sharing its own link would read as online. The OS raises no AP of its own any
// more, so this is a guard against a future shared-mode feature rather than a
// live path — and `online-once` is sticky, cleared only by a factory reset.
func (nm *NetworkManager) NetInfo() NetStatus {
	nmObj := nm.conn.Object(nmService, nmPath)

	// Prefer the primary (default-route) connection; fall back to any activated one.
	var candidates []dbus.ObjectPath
	if v, err := nmObj.GetProperty(nmIface + ".PrimaryConnection"); err == nil {
		if p, ok := v.Value().(dbus.ObjectPath); ok && p != "/" {
			candidates = append(candidates, p)
		}
	}
	if len(candidates) == 0 {
		if v, err := nmObj.GetProperty(nmIface + ".ActiveConnections"); err == nil {
			if ps, ok := v.Value().([]dbus.ObjectPath); ok {
				candidates = append(candidates, ps...)
			}
		}
	}

	for _, p := range candidates {
		ac := nm.conn.Object(nmService, p)
		state := uint32(0)
		if v, err := ac.GetProperty(nmActiveConn + ".State"); err == nil {
			state, _ = v.Value().(uint32)
		}
		if state != nmActiveStateActivated {
			continue
		}
		if nm.isProvisioningAP(p) {
			continue
		}
		var typ, id string
		if v, err := ac.GetProperty(nmActiveConn + ".Type"); err == nil {
			typ, _ = v.Value().(string)
		}
		if v, err := ac.GetProperty(nmActiveConn + ".Id"); err == nil {
			id, _ = v.Value().(string)
		}
		return NetStatus{Connected: true, Type: friendlyType(typ), Name: id}
	}
	return NetStatus{Connected: false}
}

// isProvisioningAP reports whether an active connection is a hotspot rather than
// a real uplink. It reads the connection's own settings rather than trusting the
// profile id, so an AP left running across a daemon restart is still recognised.
// Either marker is enough: mode=ap means we are beaconing, and ipv4 method=shared
// means we are handing out leases instead of holding one.
func (nm *NetworkManager) isProvisioningAP(ac dbus.ObjectPath) bool {
	acObj := nm.conn.Object(nmService, ac)
	v, err := acObj.GetProperty(nmActiveConn + ".Connection")
	if err != nil {
		return false
	}
	settingsPath, ok := v.Value().(dbus.ObjectPath)
	if !ok || settingsPath == "/" {
		return false
	}
	var settings map[string]map[string]dbus.Variant
	if err := nm.conn.Object(nmService, settingsPath).
		Call(nmSettingsCon+".GetSettings", 0).Store(&settings); err != nil {
		return false
	}
	if w, ok := settings["802-11-wireless"]; ok {
		if mode, ok := w["mode"].Value().(string); ok && mode == "ap" {
			return true
		}
	}
	if ip4, ok := settings["ipv4"]; ok {
		if method, ok := ip4["method"].Value().(string); ok && method == "shared" {
			return true
		}
	}
	return false
}

func friendlyType(nmType string) string {
	switch nmType {
	case "802-3-ethernet":
		return "ethernet"
	case "802-11-wireless":
		return "wifi"
	default:
		return nmType
	}
}

// Connected is the live gate between RECONNECT and READY.
func (nm *NetworkManager) Connected() bool { return nm.NetInfo().Connected }

// Provision adds a persistent Wi-Fi connection and activates it immediately.
// A blank psk provisions an open network. It returns once NetworkManager has
// accepted the connection (activation continues asynchronously).
func (nm *NetworkManager) Provision(ssid, psk string) error {
	if nm.wifiDevice() == "" {
		return fmt.Errorf("no Wi-Fi device")
	}
	// Clear a soft rfkill first. A blocked radio parks the device in UNAVAILABLE
	// and the owner watches "Connecting…" forever with nothing to act on — and
	// since the seed file is now the only way onto Wi-Fi, this is the only place
	// left that can unblock it. Best-effort: a failure here is not a reason to
	// skip the join, and the error surfaces in the log.
	if err := nm.EnableWireless(); err != nil {
		log.Printf("warning: could not enable the Wi-Fi radio: %v", err)
	}
	wireless := map[string]dbus.Variant{
		"ssid": dbus.MakeVariant([]byte(ssid)),
		"mode": dbus.MakeVariant("infrastructure"),
	}
	settings := map[string]map[string]dbus.Variant{
		"connection": {
			"id":          dbus.MakeVariant(ssid),
			"type":        dbus.MakeVariant("802-11-wireless"),
			"autoconnect": dbus.MakeVariant(true),
		},
		"802-11-wireless": wireless,
		"ipv4":            {"method": dbus.MakeVariant("auto")},
		"ipv6":            {"method": dbus.MakeVariant("auto")},
	}
	if psk != "" {
		settings["802-11-wireless"]["security"] = dbus.MakeVariant("802-11-wireless-security")
		settings["802-11-wireless-security"] = map[string]dbus.Variant{
			"key-mgmt": dbus.MakeVariant("wpa-psk"),
			"psk":      dbus.MakeVariant(psk),
		}
	}

	obj := nm.conn.Object(nmService, nmPath)
	var connPath, activePath dbus.ObjectPath
	err := obj.Call(nmIface+".AddAndActivateConnection", 0,
		settings, nm.wifiDevice(), dbus.ObjectPath("/")).Store(&connPath, &activePath)
	if err != nil {
		return fmt.Errorf("AddAndActivateConnection: %w", err)
	}
	return nil
}

// EnableWireless clears a soft rfkill so the radio can be used. Without it a
// blocked radio parks the device in UNAVAILABLE and the user watches a spinner
// forever with nothing to act on.
func (nm *NetworkManager) EnableWireless() error {
	obj := nm.conn.Object(nmService, nmPath)
	return obj.SetProperty(nmIface+".WirelessEnabled", dbus.MakeVariant(true))
}

// ForgetWifiProfiles deletes every saved Wi-Fi connection. Called by factory
// reset, so that a reset device genuinely comes back onboardable rather than
// silently rejoining the network it was reset away from.
func (nm *NetworkManager) ForgetWifiProfiles() error {
	var firstErr error
	for _, c := range nm.listConnections() {
		_, settings := nm.connectionInfo(c)
		conn, ok := settings["connection"]
		if !ok {
			continue
		}
		if typ, ok := conn["type"].Value().(string); !ok || typ != "802-11-wireless" {
			continue
		}
		if err := nm.conn.Object(nmService, c).Call(nmSettingsCon+".Delete", 0).Err; err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (nm *NetworkManager) listConnections() []dbus.ObjectPath {
	var conns []dbus.ObjectPath
	if err := nm.conn.Object(nmService, nmSettingsPth).
		Call(nmSettings+".ListConnections", 0).Store(&conns); err != nil {
		return nil
	}
	return conns
}

func (nm *NetworkManager) connectionInfo(c dbus.ObjectPath) (string, map[string]map[string]dbus.Variant) {
	var settings map[string]map[string]dbus.Variant
	if err := nm.conn.Object(nmService, c).Call(nmSettingsCon+".GetSettings", 0).Store(&settings); err != nil {
		return "", nil
	}
	id := ""
	if conn, ok := settings["connection"]; ok {
		id, _ = conn["id"].Value().(string)
	}
	return id, settings
}

// JoinResult distinguishes the ways a join can end, so the portal and the tablet
// splash can say something a person can act on.
type JoinResult struct {
	OK     bool
	Reason string // human-readable, empty when OK
}
