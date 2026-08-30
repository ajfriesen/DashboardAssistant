package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

// tempState points the state-file vars this package reads at a fresh directory,
// restoring them afterwards. The paths are package vars derived from stateDir at
// init, so a test has to redirect the individual ones it touches.
func tempState(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	oldMarker, oldPaired := markerFile, pairedMarker
	markerFile, pairedMarker = dir+"/provisioned", dir+"/paired"
	t.Cleanup(func() { markerFile, pairedMarker = oldMarker, oldPaired })
	return dir
}

func TestPairingOpenOnFreshDevice(t *testing.T) {
	tempState(t)
	if !NewPairing("tok").open() {
		t.Fatal("a device that has never paired must accept a claim")
	}
}

// The regression this gate was rewritten for: a seed file carrying ha_url marks
// the device provisioned before Home Assistant has ever seen it, and that used to
// close pairing on a device nobody had paired.
func TestPairingOpenOnSeededDevice(t *testing.T) {
	tempState(t)
	if err := markProvisioned(); err != nil {
		t.Fatalf("markProvisioned: %v", err)
	}
	if !NewPairing("tok").open() {
		t.Fatal("provisioned-but-unpaired device must still accept a claim")
	}
}

// Claiming alone must not close the window: Home Assistant may fail to act on the
// token, and the retry has to work without a factory reset.
func TestClaimDoesNotClosePairing(t *testing.T) {
	tempState(t)
	p := NewPairing("tok")
	if tok, ok := p.Claim(); !ok || tok != "tok" {
		t.Fatalf("first claim = (%q, %v), want (tok, true)", tok, ok)
	}
	if tok, ok := p.Claim(); !ok || tok != "tok" {
		t.Fatalf("retry claim = (%q, %v), want (tok, true)", tok, ok)
	}
}

// Using the token is what closes it.
func TestPairingClosesOnFirstTokenUse(t *testing.T) {
	tempState(t)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}
	handler := h.auth(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })

	req := httptest.NewRequest(http.MethodGet, "/api/ha/state", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	handler(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("authenticated request = %d, want %d", rec.Code, http.StatusNoContent)
	}
	if !Paired() {
		t.Fatal("a successful authenticated request must mark the device paired")
	}
	if _, ok := h.pair.Claim(); ok {
		t.Fatal("pairing must be closed once the token has been used")
	}
}

// A rejected token proves nothing, so it must leave the window open.
func TestBadTokenDoesNotClosePairing(t *testing.T) {
	tempState(t)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}
	handler := h.auth(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })

	req := httptest.NewRequest(http.MethodGet, "/api/ha/state", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	handler(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad token = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
	if Paired() {
		t.Fatal("a rejected token must not mark the device paired")
	}
}

// Factory reset is the documented way back into pairing.
func TestFactoryResetReopensPairing(t *testing.T) {
	tempState(t)
	if err := markPaired(); err != nil {
		t.Fatalf("markPaired: %v", err)
	}
	if NewPairing("tok").open() {
		t.Fatal("paired device must be closed before the reset")
	}
	if err := clearProvisioningState(); err != nil {
		t.Fatalf("clearProvisioningState: %v", err)
	}
	if !NewPairing("tok").open() {
		t.Fatal("factory reset must reopen pairing")
	}
}

// Auto-confirm overrides the marker, for fleets re-enrolled without a reset.
func TestPairAutoConfirmOverridesPaired(t *testing.T) {
	tempState(t)
	if err := markPaired(); err != nil {
		t.Fatalf("markPaired: %v", err)
	}
	t.Setenv("DASHBOARD_ASSISTANT_PAIR_AUTO", "1")
	if !NewPairing("tok").open() {
		t.Fatal("auto-confirm must keep pairing open on a paired device")
	}
}

// The pairing endpoint answers on the LAN listener but never on the setup AP,
// whose join credential is printed on the device's own screen.
func TestPairRefusedOnSetupAP(t *testing.T) {
	tempState(t)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}
	handler := notOnSetupAP(http.HandlerFunc(h.handlePair))

	req := httptest.NewRequest(http.MethodPost, "/api/ha/pair", nil)
	local := &net.TCPAddr{IP: net.ParseIP(apAddress), Port: 8081}
	req = req.WithContext(context.WithValue(req.Context(), http.LocalAddrContextKey, local))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("pair over the setup AP = %d, want %d", rec.Code, http.StatusForbidden)
	}
	if _, err := os.Stat(pairedMarker); err == nil {
		t.Fatal("a refused request must not mark the device paired")
	}
}

// withStubRestart swaps the session restart for a counter and shrinks the
// coalescing window, restoring both afterwards.
func withStubRestart(t *testing.T, window time.Duration) *atomic.Int32 {
	t.Helper()
	var calls atomic.Int32
	oldFn, oldWindow := kioskRestartFn, kioskRestartWindow
	kioskRestartFn = func() error { calls.Add(1); return nil }
	kioskRestartWindow = window
	t.Cleanup(func() {
		kioskRestartFn, kioskRestartWindow = oldFn, oldWindow
		kioskRestartMu.Lock()
		lastKioskRestart, kioskRestartQueued = time.Time{}, false
		kioskRestartMu.Unlock()
	})
	kioskRestartMu.Lock()
	lastKioskRestart, kioskRestartQueued = time.Time{}, false
	kioskRestartMu.Unlock()
	return &calls
}

// A burst must collapse, but the last caller must still be honoured: dropping it
// loses the state change that prompted it (this is what left a paired tablet on
// the login screen).
func TestRestartKioskCoalescesInsteadOfDropping(t *testing.T) {
	calls := withStubRestart(t, 100*time.Millisecond)

	for i := 0; i < 5; i++ {
		if err := restartKiosk(); err != nil {
			t.Fatalf("restartKiosk: %v", err)
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("immediate restarts = %d, want 1 (the rest must coalesce)", got)
	}

	deadline := time.Now().Add(2 * time.Second)
	for calls.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("restarts after the window = %d, want 2 (one immediate, one deferred)", got)
	}

	// The deferred pass must not itself re-arm and restart forever.
	time.Sleep(300 * time.Millisecond)
	if got := calls.Load(); got != 2 {
		t.Fatalf("restarts settled at %d, want 2 (the queue must drain, not loop)", got)
	}
}

// Calls spaced beyond the window are unrelated events and each must land.
func TestRestartKioskOutsideWindowRunsImmediately(t *testing.T) {
	calls := withStubRestart(t, 20*time.Millisecond)

	if err := restartKiosk(); err != nil {
		t.Fatalf("restartKiosk: %v", err)
	}
	time.Sleep(60 * time.Millisecond)
	if err := restartKiosk(); err != nil {
		t.Fatalf("restartKiosk: %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("spaced restarts = %d, want 2", got)
	}
}
