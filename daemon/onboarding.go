package main

// Wi-Fi onboarding: the SoftAP + captive-portal flow every other IoT device has.
//
// A device flashed from a released image, with no seed file and no Ethernet, used
// to show "Connecting to your network…" forever — the LAN admin page needs the
// network it cannot join, so the only ways out were a USB stick or a reflash.
// Instead, such a device now raises its own WPA2 access point. You join it from a
// phone (the tablet shows the name, the password and a WIFI: QR code), a captive
// portal opens, you type your network's name and password, and the device joins
// and tears the AP down.
//
// This file owns the decision and the radio. Two rules keep it honest:
//
//   - The AP only ever exists on a device that has never been online and is not
//     provisioned. A deployed tablet that loses Wi-Fi shows a reconnect splash and
//     stays quiet. The AP is unauthenticated by nature, so it must only exist when
//     there is nothing on the device worth taking.
//   - Everything that touches the radio goes through this manager's mutex,
//     including the USB seed importer. Otherwise a stick inserted mid-onboarding
//     has NetworkManager yank the radio out from under the portal.
//
// deriveState only *reads* the published flag here. It must never raise the AP as
// a side effect: it is called from an HTTP handler the splash polls every 5s, and
// concurrent polls would race into double activation.

import (
	"crypto/rand"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/godbus/dbus/v5"
)

// apPSKFile persists the hotspot passphrase. Deliberately kept across a factory
// reset: it may be on a printed label or in a photo somebody took, and there is
// nothing to gain by rotating a credential whose whole job is to be readable off
// the screen of the device it protects.
var apPSKFile = stateDir + "/ap-psk"

const (
	// apPSKAlphabet omits glyphs that are ambiguous in a display font. Somebody
	// may have to read this off a wall-mounted screen and type it on a phone.
	apPSKAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"
	apPSKLen      = 10

	// bootFloor is the earliest the AP may appear. NetworkManager's own DHCP
	// timeout is 45s, so anything shorter routinely stomps on a connection that
	// was about to succeed.
	bootFloor = 60 * time.Second

	// settleFor is how long the "nothing is happening" condition has to hold
	// before we seize the radio.
	settleFor = 15 * time.Second

	// joinTimeout bounds a single association+DHCP attempt from the portal.
	joinTimeout = 45 * time.Second

	// seedUnit provisions from /boot on first boot. It retries curl for ~10-15s,
	// during which a seeded device looks exactly like an unseeded one, so
	// onboarding waits for it to reach a terminal state before raising an AP.
	seedUnit = "dashboard-assistant-boot-import.service"
)

// Onboarding manages the setup access point and the join attempts made from the
// captive portal.
type Onboarding struct {
	nm      *NetworkManager
	channel string
	started time.Time

	// active is read by deriveState on every /api/state poll, so it is atomic
	// rather than mutex-guarded: the state endpoint must never block on a radio
	// operation that takes tens of seconds.
	active atomic.Bool

	mu       sync.Mutex // held across every radio operation
	ssid     string
	psk      string
	joining  bool
	lastErr  string
	lastSSID string
	// calm is when the "nothing is activating" condition first became true; zero
	// while something is still in flight.
	calm time.Time
}

func NewOnboarding(nm *NetworkManager, channel string) *Onboarding {
	return &Onboarding{nm: nm, channel: channel, started: time.Now()}
}

// Active reports whether the setup AP is currently up. Cheap and lock-free.
func (o *Onboarding) Active() bool { return o.active.Load() }

// APInfo is what the tablet splash and the portal need to render.
type APInfo struct {
	Active    bool   `json:"active"`
	SSID      string `json:"ssid"`
	PSK       string `json:"psk"`
	PortalURL string `json:"portal_url"`
	QRPayload string `json:"qr_payload"`
	Joining   bool   `json:"joining"`
	LastError string `json:"last_error"`
	// The network name of the failed attempt, so the portal can pre-fill it and
	// the user does not retype a long SSID to fix a one-character password typo.
	SSIDAttempt string `json:"ssid_attempt"`
}

func (o *Onboarding) Info() APInfo {
	o.mu.Lock()
	defer o.mu.Unlock()
	return APInfo{
		Active:      o.active.Load(),
		SSID:        o.ssid,
		PSK:         o.psk,
		PortalURL:   "http://" + apAddress + "/",
		QRPayload:   wifiQRPayload(o.ssid, o.psk),
		Joining:     o.joining,
		LastError:   o.lastErr,
		SSIDAttempt: o.lastSSID,
	}
}

// wifiQRPayload builds the WIFI: URI that iOS and Android cameras join directly.
// The format is picky: T:WPA (not WPA2), a trailing double semicolon, and
// backslash-escaping for the delimiter characters inside the SSID and password.
// The generated PSK alphabet contains none of them, but the escaping is applied
// anyway so a hand-set SSID cannot silently produce an unscannable code.
func wifiQRPayload(ssid, psk string) string {
	if ssid == "" {
		return ""
	}
	return fmt.Sprintf("WIFI:T:WPA;S:%s;P:%s;H:false;;", qrEscape(ssid), qrEscape(psk))
}

func qrEscape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `;`, `\;`, `,`, `\,`, `:`, `\:`, `"`, `\"`)
	return r.Replace(s)
}

// WithRadio runs fn while holding the radio, tearing the AP down first if it is
// up. The USB seed importer calls this so a stick inserted mid-onboarding wins
// cleanly instead of fighting the portal for the interface.
func (o *Onboarding) WithRadio(fn func() error) error {
	if o == nil {
		return fn()
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	o.stopLocked()
	return fn()
}

// Run is the manager loop: raise the AP when the device is stranded, tear it down
// the moment a real connection appears. Mirrors watchReadyTransition's shape.
func (o *Onboarding) Run() {
	if o.nm == nil || !o.nm.HasWifi() {
		return // wired-only host: nothing to onboard, keep today's behaviour
	}
	if !o.nm.CanAP() {
		// Several USB dongles cannot beacon. Promising an AP that will never
		// appear is worse than the plain "connecting" splash, so say so once and
		// stand down.
		log.Printf("onboarding: Wi-Fi device cannot run an access point; setup AP disabled")
		return
	}
	for range time.Tick(3 * time.Second) {
		o.tick()
	}
}

func (o *Onboarding) tick() {
	o.mu.Lock()
	defer o.mu.Unlock()

	if o.joining {
		return // a join is in flight and owns the radio
	}

	// NetInfo excludes AP/shared connections, so this means a *real* uplink.
	if o.nm.Connected() {
		if o.active.Load() {
			log.Printf("onboarding: network is up, taking the setup AP down")
			o.stopLocked()
		}
		o.calm = time.Time{}
		return
	}

	if o.active.Load() {
		return // AP is up and doing its job
	}
	if !o.shouldRaiseLocked() {
		return
	}
	if err := o.startLocked(); err != nil {
		log.Printf("onboarding: could not raise the setup AP: %v", err)
		o.calm = time.Time{} // back off and re-satisfy the settle window
	}
}

// shouldRaiseLocked decides whether this device is genuinely stranded.
func (o *Onboarding) shouldRaiseLocked() bool {
	// "Never been online and not provisioned." WasOnline is the load-bearing half:
	// it is set the first time the device reaches the network and is only cleared
	// by a factory reset, so a tablet that has ever worked never raises an AP.
	if Provisioned() || WasOnline() {
		return false
	}
	if time.Since(o.started) < bootFloor {
		return false
	}
	// A seed file on /boot provisions this device without any AP. Its unit retries
	// for ~15s and a Wi-Fi-only seed never sets the provisioned marker, so the
	// markers above cannot see it; ask systemd directly.
	if !seedImportSettled() {
		return false
	}
	if o.nm.Settling() {
		o.calm = time.Time{}
		return false
	}
	if o.calm.IsZero() {
		o.calm = time.Now()
		return false
	}
	return time.Since(o.calm) >= settleFor
}

func (o *Onboarding) startLocked() error {
	psk, err := apPSK()
	if err != nil {
		return fmt.Errorf("ap psk: %w", err)
	}
	ssid := apSSID()
	if _, err := o.nm.StartAP(ssid, psk, o.channel); err != nil {
		return err
	}
	o.ssid, o.psk = ssid, psk
	o.active.Store(true)
	log.Printf("onboarding: setup AP %q is up on %s", ssid, apAddress)
	return nil
}

func (o *Onboarding) stopLocked() {
	if !o.active.Load() {
		return
	}
	if err := o.nm.StopAP(); err != nil {
		log.Printf("onboarding: tearing down the setup AP: %v", err)
	}
	o.active.Store(false)
}

// Join is what the portal's button calls. It takes the radio down, attempts the
// join, and on failure puts the AP back so the user can rejoin and read the error.
//
// The caller must have already written and flushed its HTTP response: the phone's
// association dies the instant the radio leaves AP mode, so there is no second
// response to send it.
func (o *Onboarding) Join(ssid, psk string) {
	o.mu.Lock()
	if o.joining {
		o.mu.Unlock()
		return
	}
	o.joining = true
	o.lastErr = ""
	o.lastSSID = ssid
	o.stopLocked()
	o.mu.Unlock()

	log.Printf("onboarding: joining %q", ssid)
	res, err := o.nm.JoinAndWait(ssid, psk, joinTimeout)

	o.mu.Lock()
	defer o.mu.Unlock()
	o.joining = false

	switch {
	case err != nil:
		o.lastErr = "Could not join " + ssid
		log.Printf("onboarding: join %q failed: %v", ssid, err)
	case !res.OK:
		o.lastErr = res.Reason
		log.Printf("onboarding: join %q rejected: %s", ssid, res.Reason)
	default:
		log.Printf("onboarding: joined %q", ssid)
		o.lastSSID = ""
		markOnline()
		return // stay down; the splash walks itself to SETUP and then READY
	}
	// Failed. Put the AP back so the user can rejoin from their phone and be told
	// what went wrong, rather than watching the network vanish without explanation.
	if err := o.startLocked(); err != nil {
		log.Printf("onboarding: could not re-raise the setup AP after a failed join: %v", err)
	}
}

// apSSID names the hotspot after the device, matching the MAC-derived hostname
// from set-hostname-from-mac so the AP, the mDNS name and the HA device all agree.
func apSSID() string {
	if h := hostname(); h != "" && h != "unknown" {
		return h
	}
	if s := macSuffix(); s != "" {
		return "dashboard-assistant-" + s
	}
	return "dashboard-assistant"
}

// apPSK reads the persisted hotspot passphrase, generating one on first use.
func apPSK() (string, error) {
	if b, err := os.ReadFile(apPSKFile); err == nil {
		if psk := strings.TrimSpace(string(b)); len(psk) >= 8 {
			return psk, nil
		}
	}
	psk, err := randomPSK()
	if err != nil {
		return "", err
	}
	if err := ensureStateDir(); err != nil {
		return "", err
	}
	tmp := apPSKFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(psk+"\n"), 0o640); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, apPSKFile); err != nil {
		return "", err
	}
	return psk, nil
}

func randomPSK() (string, error) {
	out := make([]byte, apPSKLen)
	max := big.NewInt(int64(len(apPSKAlphabet)))
	for i := range out {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		out[i] = apPSKAlphabet[n.Int64()]
	}
	return string(out), nil
}

// seedImportSettled reports whether the first-boot seed importer has finished (or
// was never going to run). Without this gate a seeded device races its own
// provisioning and can raise an AP seconds before the seed lands.
func seedImportSettled() bool {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return true // cannot ask; do not strand the device on our uncertainty
	}
	defer conn.Close()

	systemd := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	var unit dbus.ObjectPath
	if err := systemd.Call("org.freedesktop.systemd1.Manager.LoadUnit", 0, seedUnit).Store(&unit); err != nil {
		return true // unit not present in this build
	}
	v, err := conn.Object("org.freedesktop.systemd1", unit).
		GetProperty("org.freedesktop.systemd1.Unit.ActiveState")
	if err != nil {
		return true
	}
	state, _ := v.Value().(string)
	// "activating" is the only state that means "still might provision us".
	// "inactive" covers both "already finished" and "ConditionPathExists said no".
	return state != "activating"
}
