package main

import (
	"os/exec"
	"testing"
)

// sourced runs runtime.env through sh the way the kiosk scripts do and returns
// the value the shell ends up with, so a test sees what the kiosk would see.
func sourced(t *testing.T, name string) string {
	t.Helper()
	out, err := exec.Command("sh", "-c", `. "$1" && printf %s "$`+name+`"`, "sh", runtimeEnv).CombinedOutput()
	if err != nil {
		t.Fatalf("sourcing runtime.env: %v: %s", err, out)
	}
	return string(out)
}

// The kiosk login carries two URLs: where Home Assistant lives (the login goes
// there) and the device's home (where it starts and where Home goes). Both
// reach the kiosk exactly as given.
func TestKioskURLsReachTheKiosk(t *testing.T) {
	tempState(t)
	ha := "http://ha.example:8123"
	home := "http://ha.example:8123/dashboard-kitchen/lights"

	if err := writeKioskURLs(ha, home); err != nil {
		t.Fatalf("writeKioskURLs: %v", err)
	}

	if got := sourced(t, "HA_URL"); got != ha {
		t.Errorf("HA_URL = %q, want %q", got, ha)
	}
	if got := sourced(t, "HOME_URL"); got != home {
		t.Errorf("HOME_URL = %q, want %q", got, home)
	}
	if got, _ := readHAURL(); got != ha {
		t.Errorf("readHAURL = %q, want %q", got, ha)
	}
}

// A home URL with a query string must not be cut off or run as a command when
// the kiosk sources runtime.env: an unquoted `&` would background the line.
func TestAHomeURLWithAQueryIsSourcedWhole(t *testing.T) {
	tempState(t)
	home := "https://example.com/view?a=1&b=2;c=$(x)"

	if err := writeKioskURLs("http://ha.example:8123", home); err != nil {
		t.Fatalf("writeKioskURLs: %v", err)
	}

	if got := sourced(t, "HOME_URL"); got != home {
		t.Errorf("HOME_URL = %q, want %q", got, home)
	}
}

// Without a home URL the kiosk falls back to Home Assistant's, so the file
// carries no stale home from an earlier login.
func TestNoHomeURLLeavesNoHome(t *testing.T) {
	tempState(t)
	if err := writeKioskURLs("http://ha.example:8123", "http://other.example/"); err != nil {
		t.Fatal(err)
	}
	if err := writeKioskURLs("http://ha.example:8123", ""); err != nil {
		t.Fatal(err)
	}
	if got := sourced(t, "HOME_URL"); got != "" {
		t.Errorf("HOME_URL = %q, want it gone", got)
	}
}

func TestKioskURLsAreChecked(t *testing.T) {
	for _, bad := range []string{
		"homeassistant.local:8123",
		"ftp://ha.example/",
		"http://",
		"http://ha.example/it's",
		"http://ha.example/a\nHA_URL=x",
		"javascript:alert(1)",
	} {
		if err := checkKioskURL(bad); err == nil {
			t.Errorf("checkKioskURL(%q) = nil, want an error", bad)
		}
	}
	for _, good := range []string{
		"http://homeassistant.local:8123/",
		"https://example.com/view?a=1&b=2",
	} {
		if err := checkKioskURL(good); err != nil {
			t.Errorf("checkKioskURL(%q) = %v, want nil", good, err)
		}
	}
}
