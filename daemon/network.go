package main

import (
	"fmt"

	"github.com/godbus/dbus/v5"
)

// NetworkManager D-Bus constants.
const (
	nmService    = "org.freedesktop.NetworkManager"
	nmPath       = "/org/freedesktop/NetworkManager"
	nmIface      = "org.freedesktop.NetworkManager"
	nmDevIface   = "org.freedesktop.NetworkManager.Device"
	nmWifiIface  = "org.freedesktop.NetworkManager.Device.Wireless"
	nmActiveConn = "org.freedesktop.NetworkManager.Connection.Active"

	// NMDeviceType.WIFI
	nmDeviceTypeWifi uint32 = 2
	// NMActiveConnectionState.ACTIVATED
	nmActiveStateActivated uint32 = 2
)

// NetworkManager wraps the system-bus connection and the Wi-Fi device path.
type NetworkManager struct {
	conn    *dbus.Conn
	wifiDev dbus.ObjectPath
}

// NewNetworkManager connects to the system bus and locates the first Wi-Fi device.
func NewNetworkManager() (*NetworkManager, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("connect system bus: %w", err)
	}
	nm := &NetworkManager{conn: conn}
	// A Wi-Fi device is optional: wired-only hosts (e.g. QEMU) still get a
	// working D-Bus layer for connection detection and config-only provisioning.
	if dev, err := nm.findWifiDevice(); err == nil {
		nm.wifiDev = dev
	}
	return nm, nil
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
	if nm.wifiDev == "" {
		return fmt.Errorf("no Wi-Fi device")
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
		settings, nm.wifiDev, dbus.ObjectPath("/")).Store(&connPath, &activePath)
	if err != nil {
		return fmt.Errorf("AddAndActivateConnection: %w", err)
	}
	return nil
}
