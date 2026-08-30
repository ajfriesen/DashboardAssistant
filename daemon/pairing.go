package main

import "os"

// Pairing implements typing-free enrollment of the device into Home Assistant.
// The Home Assistant config flow fetches the device's API token automatically
// over an unauthenticated endpoint on the LAN listener (POST /api/ha/pair), and
// that endpoint only answers while the device has not yet been paired.
//
// The gate used to be "is the device unprovisioned", which conflated two
// unrelated facts: whether the device knows its Home Assistant URL, and whether
// it has already handed its token to anyone. That broke every preconfigured
// device — a seed file carrying ha_url marks the device provisioned before it has
// ever met Home Assistant, so pairing was refused on a device nobody had paired.
// The question that actually matters is whether the token has already reached the
// integration, so that is what is asked now.
//
// The window therefore closes on first *use* of the token (see HAHub.notePaired),
// not on the claim itself. A claim Home Assistant fails to complete — it cannot
// reach the device back, the flow is abandoned halfway — leaves pairing open, so
// retrying works instead of requiring a factory reset.
//
// There used to be an on-screen "Pair" button that armed a 90-second window on a
// provisioned device, on the theory that reaching the loopback Config panel proved
// physical presence. That theory does not survive a tablet on a hallway wall, so
// the button and the window are gone. Re-pairing goes through a factory reset,
// which clears the paired marker along with the rest of the device's state. The
// token is still only ever handed out over the LAN listener, never broadcast in
// mDNS, and never over the Wi-Fi setup AP (see notOnSetupAP).
//
// Upgrade note: a device that was already paired under the old rule has no marker
// yet, so its window reopens until the integration's next authenticated request
// writes one — which is immediate on any live install, since the coordinator
// connects and opens its event stream as soon as it can reach the device. There is
// deliberately no migration that infers the marker from the provisioned flag: that
// flag is exactly the thing that cannot tell a paired device from a seeded one,
// and guessing wrong would relock the devices this change exists to unblock.
type Pairing struct {
	token string
	auto  bool // window always open (preprovisioned fleet)
}

// NewPairing builds the pairing gate for the device token. Auto-confirm is read
// once at start: it is a build property, not a runtime toggle.
func NewPairing(token string) *Pairing {
	return &Pairing{token: token, auto: pairAutoConfirm()}
}

// pairAutoConfirm reports whether the pairing window is always open — repeatable
// zero-touch enrollment for fleets that are re-added to Home Assistant without a
// factory reset, set via dashboardAssistant.haApi.pairAutoConfirm in the image.
// Devices on an untrusted network should leave it off; a reset is then the way to
// re-pair.
func pairAutoConfirm() bool {
	return os.Getenv("DASHBOARD_ASSISTANT_PAIR_AUTO") == "1"
}

// open reports whether pairing accepts a claim: the build auto-confirms, or the
// device has never been paired. A kiosk that has not been added to Home Assistant
// yet pairs with no on-device step, whether it was set up by hand or seeded from a
// USB stick. Once Home Assistant has used the token the device locks, and the way
// back is a factory reset from the admin page.
func (p *Pairing) open() bool {
	return p.auto || !Paired()
}

// Claim returns the token when pairing is open. Returns ("", false) otherwise.
func (p *Pairing) Claim() (string, bool) {
	if p.open() {
		return p.token, true
	}
	return "", false
}
