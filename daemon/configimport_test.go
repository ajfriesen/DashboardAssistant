package main

import (
	"os"
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
	if !contains(applied, "kiosk_token") {
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
	if !contains(applied, "kiosk_token") {
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

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
