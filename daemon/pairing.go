package main

import (
	"os"
	"sync"
	"time"
)

// Pairing implements typing-free, presence-gated enrollment of the device into
// Home Assistant. The device's HA API token is a secret the operator otherwise
// has to read off the Config screen and type into Home Assistant by hand. Instead
// the Home Assistant config flow fetches it automatically over an unauthenticated
// endpoint on the LAN listener (POST /api/ha/pair) — but only during a short
// window the operator opens by pressing "Pair" on the loopback Config panel.
// Reaching that panel already requires physical presence at the device (the kiosk
// Config button navigates the local browser to the loopback :8080 surface), so
// arming the window is the authorization. Outside the window the endpoint reveals
// nothing. A preseeded/fleet build can hold the window permanently open for
// zero-touch enrollment (see pairAutoConfirm); the token is still only ever handed
// out over the LAN listener, never broadcast in mDNS.
type Pairing struct {
	token string
	auto  bool // window always open (preprovisioned fleet)

	mu         sync.Mutex
	armedUntil time.Time
}

// pairWindow is how long a single "Pair" press keeps the hand-off open. Long
// enough to switch to Home Assistant and add the discovered device, short enough
// that a forgotten window closes on its own.
const pairWindow = 90 * time.Second

// NewPairing builds the pairing gate for the device token. Auto-confirm is read
// once at start: it is a build/seed property, not a runtime toggle.
func NewPairing(token string) *Pairing {
	return &Pairing{token: token, auto: pairAutoConfirm()}
}

// pairAutoConfirm reports whether the pairing window is always open — zero-touch
// enrollment for preprovisioned fleets, set via the Nix module / seed. Devices on
// an untrusted network should leave it off and use the on-screen Pair button.
func pairAutoConfirm() bool {
	return os.Getenv("DASHBOARD_ASSISTANT_PAIR_AUTO") == "1"
}

// Arm opens the pairing window for pairWindow, returning when it expires. Called
// from the loopback Config screen when the operator presses "Pair".
func (p *Pairing) Arm() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.armedUntil = time.Now().Add(pairWindow)
	return p.armedUntil
}

// Disarm closes the window immediately (the operator cancelled).
func (p *Pairing) Disarm() {
	p.mu.Lock()
	p.armedUntil = time.Time{}
	p.mu.Unlock()
}

// open reports whether pairing accepts a claim without an explicit arm: the build
// auto-confirms, or the device is still unprovisioned. A fresh, never-added kiosk
// is in onboarding — it pairs with Home Assistant with no on-device step, so the
// guided "Add me in HA" screen just works. Once provisioned the device re-locks
// and re-pairing requires an explicit Pair press on the Config screen.
func (p *Pairing) open() bool {
	return p.auto || !Provisioned()
}

// Remaining returns the seconds left in the window (0 when closed), for the
// Config screen countdown and the status endpoint.
func (p *Pairing) Remaining() int {
	if p.open() {
		return int(pairWindow / time.Second)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if d := time.Until(p.armedUntil); d > 0 {
		return int(d.Seconds())
	}
	return 0
}

// Claim returns the token and closes the window when pairing is open, so a
// successful hand-off consumes it (single-shot): if a second party on the LAN
// races Home Assistant for the token, only one of them wins and the operator sees
// the other attempt fail rather than both succeeding silently. Auto-confirm never
// consumes — a fleet network is trusted and may enroll repeatedly. Returns
// ("", false) when the window is closed.
func (p *Pairing) Claim() (string, bool) {
	if p.open() {
		return p.token, true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Now().Before(p.armedUntil) {
		p.armedUntil = time.Time{} // consume the window
		return p.token, true
	}
	return "", false
}
