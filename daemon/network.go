package main

import (
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// NetworkManager D-Bus constants.
const (
	nmService     = "org.freedesktop.NetworkManager"
	nmPath        = "/org/freedesktop/NetworkManager"
	nmIface       = "org.freedesktop.NetworkManager"
	nmDevIface    = "org.freedesktop.NetworkManager.Device"
	nmWifiIface   = "org.freedesktop.NetworkManager.Device.Wireless"
	nmActiveConn  = "org.freedesktop.NetworkManager.Connection.Active"
	nmSettingsPth = "/org/freedesktop/NetworkManager/Settings"
	nmSettings    = "org.freedesktop.NetworkManager.Settings"
	nmSettingsCon = "org.freedesktop.NetworkManager.Settings.Connection"

	// NMDeviceType.WIFI
	nmDeviceTypeWifi uint32 = 2
	// NMActiveConnectionState.ACTIVATED
	nmActiveStateActivated uint32 = 2

	// NMDeviceState. Anything strictly between DISCONNECTED and ACTIVATED is a
	// transitional "busy" state; onboarding must not raise an AP during one.
	nmDevStateUnavailable  uint32 = 20
	nmDevStateDisconnected uint32 = 30
	nmDevStateActivated    uint32 = 100
	nmDevStateFailed       uint32 = 120

	// NMDeviceWifiCapabilities.AP — cleared by plenty of USB dongles whose
	// out-of-tree drivers cannot beacon. Activation would fail with a confusing
	// error, so onboarding checks this before promising the AP path.
	nmWifiCapAP uint32 = 0x40

	// NMState.CONNECTING — NM is mid-activation somewhere, so nothing is settled.
	nmStateConnecting uint32 = 40
)

// NMDeviceStateReason values worth telling a human apart. A join that fails
// deserves better than "it didn't work": these are the difference between "you
// mistyped the password" and "that network isn't in range".
const (
	nmReasonNoSecrets            uint32 = 7
	nmReasonSupplicantDisconnect uint32 = 8
	nmReasonSupplicantFailed     uint32 = 10
	nmReasonSupplicantTimeout    uint32 = 11
	nmReasonSSIDNotFound         uint32 = 53
)

// apConnID is the id of the onboarding hotspot profile. NetInfo keys off it as a
// cheap first check, but the authoritative test is the connection's own settings
// (see isProvisioningAP) so a daemon restart mid-AP still classifies correctly.
const apConnID = "dashboard-assistant-setup"

// apAddress is the AP's own address, pinned rather than left to NetworkManager.
// NM documents 10.42.x.0/24 as what it picks when a shared connection carries no
// manual address, which is a default and not a guarantee. The dnsmasq drop-in
// (wildcard DNS + the RFC 8910 captive-portal URI) and the firewall rules in
// modules/core/onboarding.nix all hardcode this address, so it has to be certain.
const apAddress = "10.42.0.1"

// NetworkManager wraps the system-bus connection and the Wi-Fi device path.
type NetworkManager struct {
	conn *dbus.Conn

	// Resolved lazily, and re-resolved for as long as we do not have one. It
	// cannot be looked up once at startup: NetworkManager registers devices
	// asynchronously, and this daemon routinely wins that race — it is ordered
	// after dbus.service and network.target, neither of which waits for a radio
	// to be probed and its supplicant attached. Caching the empty result left
	// Wi-Fi dead for the whole boot, which broke seed-file provisioning exactly
	// as badly as it broke onboarding.
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
// The onboarding hotspot is skipped, and that exclusion is load-bearing. An
// AP-mode connection is itself an ACTIVATED active connection, so without this the
// act of raising the setup AP would make the device read as online: deriveState
// would flip to SETUP, watchReadyTransition would fire markOnline, and the
// `online-once` marker is sticky and cleared only by a factory reset. One boot
// would permanently cost that device its ability to ever show the AP again.
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

// HasWifi reports whether a Wi-Fi device was found at start.
func (nm *NetworkManager) HasWifi() bool { return nm.wifiDevice() != "" }

// CanAP reports whether the Wi-Fi driver can beacon. Several USB dongles cannot,
// and NM fails the activation with a message no end user can act on, so onboarding
// checks this up front and falls back to the plain "connecting" splash instead of
// promising an access point that will never appear.
func (nm *NetworkManager) CanAP() bool {
	if nm.wifiDevice() == "" {
		return false
	}
	v, err := nm.conn.Object(nmService, nm.wifiDevice()).GetProperty(nmWifiIface + ".WirelessCapabilities")
	if err != nil {
		return false
	}
	caps, ok := v.Value().(uint32)
	return ok && caps&nmWifiCapAP != 0
}

// IfaceName is the kernel name of the Wi-Fi device ("wlan0", "wlp2s0", …). Read
// from NM rather than guessed: it differs between the Pi targets and x86, where
// systemd's predictable naming applies.
func (nm *NetworkManager) IfaceName() string {
	if nm.wifiDevice() == "" {
		return ""
	}
	v, err := nm.conn.Object(nmService, nm.wifiDevice()).GetProperty(nmDevIface + ".Interface")
	if err != nil {
		return ""
	}
	name, _ := v.Value().(string)
	return name
}

// DeviceState is the Wi-Fi device's NMDeviceState.
func (nm *NetworkManager) DeviceState() uint32 {
	if nm.wifiDevice() == "" {
		return 0
	}
	v, err := nm.conn.Object(nmService, nm.wifiDevice()).GetProperty(nmDevIface + ".State")
	if err != nil {
		return 0
	}
	state, _ := v.Value().(uint32)
	return state
}

// Settling reports whether NetworkManager is still trying to bring something up,
// anywhere. Onboarding waits for this to clear before raising an AP: NM's own DHCP
// timeout is 45 seconds, so a naive "wait 30s then start the AP" would routinely
// stomp on a connection that was about to succeed.
func (nm *NetworkManager) Settling() bool {
	v, err := nm.conn.Object(nmService, nmPath).GetProperty(nmIface + ".State")
	if err != nil {
		return true // unknown: assume busy rather than seize the radio
	}
	state, ok := v.Value().(uint32)
	if !ok {
		return true
	}
	if state == nmStateConnecting {
		return true
	}
	dev := nm.DeviceState()
	// Transitional states sit strictly between DISCONNECTED and ACTIVATED.
	return dev > nmDevStateDisconnected && dev < nmDevStateActivated
}

// EnableWireless clears a soft rfkill so the radio can be used. Without it a
// blocked radio parks the device in UNAVAILABLE and the user watches a spinner
// forever with nothing to act on.
func (nm *NetworkManager) EnableWireless() error {
	obj := nm.conn.Object(nmService, nmPath)
	return obj.SetProperty(nmIface+".WirelessEnabled", dbus.MakeVariant(true))
}

// StartAP raises the onboarding hotspot: WPA2 on 2.4 GHz, with NetworkManager
// running DHCP, DNS and NAT for it via ipv4 method=shared.
//
// Every value here is pinned on purpose:
//
//   - band "bg" and a channel in 1-11, because the device runs in the world
//     regulatory domain ("00") where 5 GHz and 2.4 GHz channels 12-14 are flagged
//     NO-IR and beaconing on them is forbidden. This is not a preference.
//   - an explicit address, so the captive-portal machinery that hardcodes it
//     (dnsmasq drop-in, firewall rules, the socket unit) is not relying on NM's
//     choice of subnet.
//   - proto/pairwise/group forced to RSN+CCMP. Left unset, wpa_supplicant also
//     beacons WPA1/TKIP, which Android flags as weak security and which some
//     drivers refuse to start an AP with at all.
//   - autoconnect false, so a profile that somehow survives cannot resurrect the
//     hotspot on a device that is happily online.
func (nm *NetworkManager) StartAP(ssid, psk, channel string) (dbus.ObjectPath, error) {
	if nm.wifiDevice() == "" {
		return "", fmt.Errorf("no Wi-Fi device")
	}
	if err := nm.EnableWireless(); err != nil {
		return "", fmt.Errorf("enable wireless: %w", err)
	}
	ch, err := strconv.ParseUint(channel, 10, 32)
	if err != nil || ch < 1 || ch > 11 {
		return "", fmt.Errorf("AP channel must be 1-11 (world regulatory domain), got %q", channel)
	}
	settings := map[string]map[string]dbus.Variant{
		"connection": {
			"id":          dbus.MakeVariant(apConnID),
			"type":        dbus.MakeVariant("802-11-wireless"),
			"autoconnect": dbus.MakeVariant(false),
		},
		"802-11-wireless": {
			"ssid":    dbus.MakeVariant([]byte(ssid)),
			"mode":    dbus.MakeVariant("ap"),
			"band":    dbus.MakeVariant("bg"),
			"channel": dbus.MakeVariant(uint32(ch)),
		},
		"802-11-wireless-security": {
			"key-mgmt": dbus.MakeVariant("wpa-psk"),
			"psk":      dbus.MakeVariant(psk),
			"proto":    dbus.MakeVariant([]string{"rsn"}),
			"pairwise": dbus.MakeVariant([]string{"ccmp"}),
			"group":    dbus.MakeVariant([]string{"ccmp"}),
		},
		"ipv4": {
			"method":             dbus.MakeVariant("shared"),
			"address-data":       dbus.MakeVariant([]map[string]dbus.Variant{{"address": dbus.MakeVariant(apAddress), "prefix": dbus.MakeVariant(uint32(24))}}),
			"never-default":      dbus.MakeVariant(true),
			"ignore-auto-dns":    dbus.MakeVariant(true),
			"ignore-auto-routes": dbus.MakeVariant(true),
		},
		"ipv6": {"method": dbus.MakeVariant("ignore")},
	}
	var connPath, activePath dbus.ObjectPath
	err = nm.conn.Object(nmService, nmPath).Call(nmIface+".AddAndActivateConnection", 0,
		settings, nm.wifiDevice(), dbus.ObjectPath("/")).Store(&connPath, &activePath)
	if err != nil {
		return "", fmt.Errorf("activate AP: %w", err)
	}
	return connPath, nil
}

// StopAP deactivates and deletes the hotspot profile. Deleting matters as much as
// deactivating: a lingering profile is one NM restart away from beaconing an
// unauthenticated provisioning network on a deployed device.
func (nm *NetworkManager) StopAP() error {
	var firstErr error
	for _, ac := range nm.activeConnections() {
		if !nm.isProvisioningAP(ac) {
			continue
		}
		if err := nm.conn.Object(nmService, nmPath).
			Call(nmIface+".DeactivateConnection", 0, ac).Err; err != nil && firstErr == nil {
			firstErr = fmt.Errorf("deactivate AP: %w", err)
		}
	}
	// Sweep the saved profiles too, so a hotspot created by an earlier daemon
	// generation (or left behind by a crash) cannot come back.
	for _, c := range nm.listConnections() {
		id, settings := nm.connectionInfo(c)
		if id != apConnID && !isAPSettings(settings) {
			continue
		}
		if err := nm.conn.Object(nmService, c).Call(nmSettingsCon+".Delete", 0).Err; err != nil && firstErr == nil {
			firstErr = fmt.Errorf("delete AP profile: %w", err)
		}
	}
	return firstErr
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

func (nm *NetworkManager) activeConnections() []dbus.ObjectPath {
	v, err := nm.conn.Object(nmService, nmPath).GetProperty(nmIface + ".ActiveConnections")
	if err != nil {
		return nil
	}
	ps, _ := v.Value().([]dbus.ObjectPath)
	return ps
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

func isAPSettings(settings map[string]map[string]dbus.Variant) bool {
	w, ok := settings["802-11-wireless"]
	if !ok {
		return false
	}
	mode, ok := w["mode"].Value().(string)
	return ok && mode == "ap"
}

// JoinResult distinguishes the ways a join can end, so the portal and the tablet
// splash can say something a person can act on.
type JoinResult struct {
	OK     bool
	Reason string // human-readable, empty when OK
}

// JoinAndWait adds a Wi-Fi profile, activates it, and blocks until the device
// either reaches ACTIVATED or fails. The old fire-and-forget Provision could not
// tell a wrong password from a slow DHCP lease, which made "it just sits there"
// the only feedback the user ever got.
//
// On failure the profile is deleted. NetworkManager persists a profile at
// AddAndActivateConnection time, before it knows the passphrase works, so without
// this a typo would leave a saved network that NM keeps retrying and that fights
// the setup AP after every reboot.
//
// Deliberately *not* using AddAndActivateConnection2 with persist=volatile, which
// would avoid ever writing a bad profile: promoting a volatile profile to disk
// afterwards can itself fail, and a device that forgets its Wi-Fi on reboot and
// re-raises the AP forever is a far worse outcome than a stale profile that the
// next successful join replaces.
func (nm *NetworkManager) JoinAndWait(ssid, psk string, timeout time.Duration) (JoinResult, error) {
	if nm.wifiDevice() == "" {
		return JoinResult{}, fmt.Errorf("no Wi-Fi device")
	}
	// Cheapest possible wrong-password check: WPA2 passphrases are 8-63 chars.
	// Costs no radio time and catches the most common typo class.
	if psk != "" && (len(psk) < 8 || len(psk) > 63) {
		return JoinResult{Reason: "Wi-Fi passwords are between 8 and 63 characters"}, nil
	}

	// Subscribe before activating. The signal is watched on the *device* rather
	// than the active connection because NM destroys the active-connection object
	// when activation fails, and a watcher on a destroyed object simply goes quiet.
	matches := []dbus.MatchOption{
		dbus.WithMatchObjectPath(nm.wifiDevice()),
		dbus.WithMatchInterface(nmDevIface),
		dbus.WithMatchMember("StateChanged"),
	}
	if err := nm.conn.AddMatchSignal(matches...); err != nil {
		return JoinResult{}, fmt.Errorf("watch device state: %w", err)
	}
	defer nm.conn.RemoveMatchSignal(matches...)
	sigs := make(chan *dbus.Signal, 16)
	nm.conn.Signal(sigs)
	defer nm.conn.RemoveSignal(sigs)

	connPath, err := nm.addAndActivate(ssid, psk)
	if err != nil {
		return JoinResult{}, err
	}

	deadline := time.After(timeout)
	for {
		select {
		case <-deadline:
			nm.deleteConnection(connPath)
			return JoinResult{Reason: "timed out joining " + ssid}, nil
		case sig := <-sigs:
			if sig == nil || sig.Path != nm.wifiDevice() || len(sig.Body) < 3 {
				continue
			}
			newState, _ := sig.Body[0].(uint32)
			reason, _ := sig.Body[2].(uint32)
			switch newState {
			case nmDevStateActivated:
				return JoinResult{OK: true}, nil
			case nmDevStateFailed, nmDevStateDisconnected:
				// NEED_AUTH on its own is not fatal: with no secret agent
				// registered, NM walks through it on its way to FAILED.
				nm.deleteConnection(connPath)
				return JoinResult{Reason: joinFailureReason(reason, ssid)}, nil
			}
		}
	}
}

func (nm *NetworkManager) addAndActivate(ssid, psk string) (dbus.ObjectPath, error) {
	settings := map[string]map[string]dbus.Variant{
		"connection": {
			"id":          dbus.MakeVariant(ssid),
			"type":        dbus.MakeVariant("802-11-wireless"),
			"autoconnect": dbus.MakeVariant(true),
		},
		"802-11-wireless": {
			"ssid": dbus.MakeVariant([]byte(ssid)),
			"mode": dbus.MakeVariant("infrastructure"),
			// Typed by hand from the portal, so it may well be a hidden network.
			// Setting this makes NM probe for the SSID instead of waiting to see
			// it in a scan; it is harmless for networks that do beacon.
			"hidden": dbus.MakeVariant(true),
		},
		"ipv4": {"method": dbus.MakeVariant("auto")},
		"ipv6": {"method": dbus.MakeVariant("auto")},
	}
	if psk != "" {
		settings["802-11-wireless"]["security"] = dbus.MakeVariant("802-11-wireless-security")
		settings["802-11-wireless-security"] = map[string]dbus.Variant{
			"key-mgmt": dbus.MakeVariant("wpa-psk"),
			"psk":      dbus.MakeVariant(psk),
		}
	}
	var connPath, activePath dbus.ObjectPath
	err := nm.conn.Object(nmService, nmPath).Call(nmIface+".AddAndActivateConnection", 0,
		settings, nm.wifiDevice(), dbus.ObjectPath("/")).Store(&connPath, &activePath)
	if err != nil {
		return "", fmt.Errorf("AddAndActivateConnection: %w", err)
	}
	return connPath, nil
}

func (nm *NetworkManager) deleteConnection(c dbus.ObjectPath) {
	if c == "" || c == "/" {
		return
	}
	_ = nm.conn.Object(nmService, c).Call(nmSettingsCon+".Delete", 0).Err
}

func joinFailureReason(reason uint32, ssid string) string {
	switch reason {
	case nmReasonNoSecrets:
		return "Wrong password for " + ssid
	case nmReasonSSIDNotFound:
		return "Could not find " + ssid + " — check the name and that it is in range"
	case nmReasonSupplicantDisconnect, nmReasonSupplicantFailed, nmReasonSupplicantTimeout:
		return "Could not connect to " + ssid + " — try again"
	default:
		return "Could not join " + ssid
	}
}
