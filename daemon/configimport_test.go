package main

import (
	"os"
	"slices"
	"strings"
	"testing"
)

// readKioskToken returns what the importer stored for the kiosk to log in with.
func readKioskToken(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(tokenFile)
	if err != nil {
		t.Fatalf("read kiosk token: %v", err)
	}
	return strings.TrimSpace(string(b))
}

// The documented key (CONTEXT.md calls it the kiosk token; a bare `token` next
// to `api_token` is ambiguous).
func TestImportKioskToken(t *testing.T) {
	tempState(t)
	s := &server{}

	applied, err := s.applyImport([]byte("kiosk_token: \"eyJhbGci.kiosk\"\n"))
	if err != nil {
		t.Fatalf("applyImport: %v", err)
	}
	if got := readKioskToken(t); got != "eyJhbGci.kiosk" {
		t.Errorf("kiosk token = %q, want the seeded one", got)
	}
	if !slices.Contains(applied, "kiosk_token") {
		t.Errorf("applied = %v, want it to report kiosk_token", applied)
	}
}

// Seed files in the field still carry the old key, and a device must not stop
// logging in because the key was renamed.
func TestImportLegacyTokenAlias(t *testing.T) {
	tempState(t)
	s := &server{}

	applied, err := s.applyImport([]byte("token: \"eyJhbGci.legacy\"\n"))
	if err != nil {
		t.Fatalf("applyImport: %v", err)
	}
	if got := readKioskToken(t); got != "eyJhbGci.legacy" {
		t.Errorf("kiosk token = %q, want the one from the deprecated key", got)
	}
	if !slices.Contains(applied, "kiosk_token") {
		t.Errorf("applied = %v, want the deprecated key reported as kiosk_token", applied)
	}
}

// A file carrying both (an operator mid-rename) must apply the current key, not
// let the deprecated one win by ordering.
func TestImportKioskTokenWinsOverLegacyAlias(t *testing.T) {
	tempState(t)
	s := &server{}

	if _, err := s.applyImport([]byte("token: \"old\"\nkiosk_token: \"new\"\n")); err != nil {
		t.Fatalf("applyImport: %v", err)
	}
	if got := readKioskToken(t); got != "new" {
		t.Errorf("kiosk token = %q, want the kiosk_token value", got)
	}
}

// Pairing hands the device its Home Assistant URL (POST /api/ha/kiosk_login),
// so the seed file no longer carries one. A file from before the change still
// has `ha_url`; it must not set the URL or mark the device provisioned, which
// would skip the add screen on a device nothing has paired, and the rest of
// the file must still apply.
func TestImportIgnoresHAURL(t *testing.T) {
	tempState(t)
	s := &server{}

	applied, err := s.applyImport([]byte("ha_url: \"http://198.51.100.7:8123\"\nkiosk_token: \"eyJhbGci.kiosk\"\n"))
	if err != nil {
		t.Fatalf("applyImport: %v", err)
	}
	if u, _ := readHAURL(); u != "" {
		t.Errorf("HA URL = %q, want none: the seed file no longer sets it", u)
	}
	if Provisioned() {
		t.Error("device marked provisioned by a seed file's ha_url")
	}
	for _, a := range applied {
		if strings.HasPrefix(a, "ha_url") {
			t.Errorf("applied = %v, want no ha_url entry", applied)
		}
	}
	if got := readKioskToken(t); got != "eyJhbGci.kiosk" {
		t.Errorf("kiosk token = %q, want the rest of the file applied", got)
	}
}
