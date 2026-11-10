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

// Home Assistant's URL reaches the kiosk exactly as given, even one the shell
// would otherwise split: the kiosk scripts source runtime.env.
func TestHAURLReachesTheKiosk(t *testing.T) {
	tempState(t)
	ha := "http://ha.example:8123/?a=1&b=2"

	if err := writeHAURL(ha); err != nil {
		t.Fatalf("writeHAURL: %v", err)
	}

	if got := sourced(t, "HA_URL"); got != ha {
		t.Errorf("HA_URL = %q, want %q", got, ha)
	}
	if got, _ := readHAURL(); got != ha {
		t.Errorf("readHAURL = %q, want %q", got, ha)
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
