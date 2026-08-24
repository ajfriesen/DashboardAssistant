package main

// LAN admin page: recovery for a device whose screen deliberately offers none.
//
// The kiosk is a wall panel that guests touch, so nothing on the screen may
// reconfigure it — the bottom bar carries navigation and the keyboard only, and
// the on-device pages (/waiting, /sponsor) are read-only. Recovery therefore has
// to arrive over the network, and it lives here rather than in the Home Assistant
// integration because the cases you need it for are exactly the ones where Home
// Assistant is unreachable.
//
// This listener is UNAUTHENTICATED, on purpose and with the trade-off understood:
// it inverts the :8080 model, where reaching loopback proves physical presence.
// Anyone who can route to the device can roll it back or factory-reset it. What
// it must never do is hand out a credential that reaches further than the device
// itself — see handleInfo, which no longer returns the API token.

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// serveAdmin runs the LAN admin listener: the recovery page and its endpoints,
// and nothing from the loopback :8080 surface.
func serveAdmin(srv *server) {
	addr := envOr("DASHBOARD_ASSISTANT_ADMIN_ADDR", ":8099")
	mux := http.NewServeMux()
	mux.HandleFunc("/", srv.handleAdminPage)
	// Identity + network. Same payload as the on-screen /api/info: read-only, and
	// with no secret in it, which is what makes it safe to expose here.
	mux.HandleFunc("/api/admin/info", srv.handleInfo)
	mux.HandleFunc("/api/admin/generations", srv.handleGenerations)
	mux.HandleFunc("/api/admin/rollback", srv.handleRollback)
	mux.HandleFunc("/api/admin/reset", srv.handleReset)
	log.Printf("admin listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("admin server error: %v", err)
	}
}

func (s *server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	serveEmbedded(w, "web/admin.html")
}

// handleGenerations lists the bootable NixOS generations for the recovery UI.
func (s *server) handleGenerations(w http.ResponseWriter, r *http.Request) {
	gens, err := listGenerations()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"generations": gens, "current": currentGeneration()})
}

// handleRollback boots into the requested generation (switches the profile and
// reboots, via the privileged dashboard-assistant-rollback@ unit). POST {"generation": N}.
// The generation number is validated here and again inside the root unit script
// (modules/core/daemon.nix) — keep both.
func (s *server) handleRollback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	var req struct {
		Generation int `json:"generation"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	if !generationExists(req.Generation) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no such generation"})
		return
	}
	if req.Generation == currentGeneration() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "already the current generation"})
		return
	}
	if err := bootGeneration(req.Generation); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	log.Printf("admin: rollback — booting generation %d", req.Generation)
	writeJSON(w, http.StatusOK, map[string]any{"state": "rebooting", "generation": req.Generation})
}

// handleReset factory-resets the device: clears provisioning + config state (HA
// URL, kiosk login token, device API token, prefs) and reboots onto the
// onboarding screen. This is also how you re-pair: a reset device is
// unprovisioned, and Pairing.open() is true while unprovisioned, so Home
// Assistant re-discovers and claims a fresh token with no on-screen step. That
// is the whole reason there is no "arm pairing" button anywhere any more.
//
// The client is expected to have collected a typed confirmation first; this
// endpoint does not second-guess it, but it does insist on POST so a stray link
// or a prefetch cannot wipe a device.
func (s *server) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	if err := clearProvisioningState(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	log.Printf("admin: factory reset — provisioning cleared, rebooting")
	writeJSON(w, http.StatusOK, map[string]string{"state": "resetting"})
	// Reboot after the response flushes so the caller sees its 200 before the box
	// goes down; the fresh boot regenerates the API token and shows onboarding.
	go func() {
		time.Sleep(time.Second)
		if err := systemReboot(); err != nil {
			log.Printf("admin: reboot after reset: %v", err)
		}
	}()
}
