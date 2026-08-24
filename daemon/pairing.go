package main

import "os"

// Pairing implements typing-free enrollment of the device into Home Assistant.
// The Home Assistant config flow fetches the device's API token automatically
// over an unauthenticated endpoint on the LAN listener (POST /api/ha/pair), and
// that endpoint only answers while the device is unprovisioned — i.e. fresh out
// of the box, or just factory-reset from the admin page.
//
// There used to be an on-screen "Pair" button that armed a 90-second window on a
// provisioned device, on the theory that reaching the loopback Config panel proved
// physical presence. That theory does not survive a tablet on a hallway wall, so
// the button and the window are gone. Re-pairing now goes through a factory reset,
// which returns the device to the unprovisioned state this gate already allows.
// The token is still only ever handed out over the LAN listener, never broadcast
// in mDNS.
type Pairing struct {
	token string
	auto  bool // window always open (preprovisioned fleet)
}

// NewPairing builds the pairing gate for the device token. Auto-confirm is read
// once at start: it is a build/seed property, not a runtime toggle.
func NewPairing(token string) *Pairing {
	return &Pairing{token: token, auto: pairAutoConfirm()}
}

// pairAutoConfirm reports whether the pairing window is always open — zero-touch
// enrollment for preprovisioned fleets, set via the Nix module / seed. Devices on
// an untrusted network should leave it off; a reset is then the way to re-pair.
func pairAutoConfirm() bool {
	return os.Getenv("DASHBOARD_ASSISTANT_PAIR_AUTO") == "1"
}

// open reports whether pairing accepts a claim: the build auto-confirms, or the
// device is still unprovisioned. A fresh, never-added kiosk is in onboarding, so
// it pairs with Home Assistant with no on-device step and the guided "Add me in
// HA" screen just works. Once provisioned the device locks, and the way back is a
// factory reset from the admin page.
func (p *Pairing) open() bool {
	return p.auto || !Provisioned()
}

// Claim returns the token when pairing is open. Returns ("", false) otherwise.
func (p *Pairing) Claim() (string, bool) {
	if p.open() {
		return p.token, true
	}
	return "", false
}
