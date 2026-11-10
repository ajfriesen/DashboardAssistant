package main

import (
	"bufio"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Home Assistant replaces the whole page list in one call: any website, in
// order, and the list survives a restart.
func TestReplacePagesKeepsTheListHomeAssistantSent(t *testing.T) {
	tempState(t)
	p := NewPages()
	want := []Page{
		{Name: "Bench", URL: "http://192.168.178.72:8123"},
		{Name: "Weather | Windy", URL: "https://www.windy.com"},
		{URL: "https://example.com/live"},
	}

	if err := p.Replace(want); err != nil {
		t.Fatalf("Replace: %v", err)
	}

	if got := p.List(); !reflect.DeepEqual(got, want) {
		t.Fatalf("List = %#v, want %#v", got, want)
	}
	b, err := os.ReadFile(urlsFile)
	if err != nil {
		t.Fatal(err)
	}
	var saved []Page
	if err := json.Unmarshal(b, &saved); err != nil || !reflect.DeepEqual(saved, want) {
		t.Fatalf("urls.json = %s, want %#v", b, want)
	}
}

// Anything the kiosk could not open is refused, and the list stays as it was.
func TestReplacePagesRefusesWhatIsNotAWebsite(t *testing.T) {
	for _, url := range []string{"ftp://files.lan", "homeassistant.local:8123", "https://", ""} {
		t.Run(url, func(t *testing.T) {
			tempState(t)
			p := NewPages()
			before := p.List()

			if err := p.Replace([]Page{{Name: "Bad", URL: url}}); err == nil {
				t.Fatalf("Replace(%q) succeeded, want an error", url)
			}
			if got := p.List(); !reflect.DeepEqual(got, before) {
				t.Fatalf("List = %#v after a refused Replace, want %#v", got, before)
			}
		})
	}
}

// navReader points the page list at a FIFO and returns what the nav agent would
// read from it, one URL per navigation.
func navReader(t *testing.T) (*Pages, func() string) {
	t.Helper()
	dir := tempState(t)
	fifo := dir + "/nav.fifo"
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DASHBOARD_ASSISTANT_NAV_FIFO", fifo)
	r, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	lines := make(chan string, 16)
	go func() {
		br := bufio.NewReader(r)
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			lines <- strings.TrimSpace(line)
		}
	}()
	return NewPages(), func() string {
		select {
		case line := <-lines:
			return line
		case <-time.After(2 * time.Second):
			return "(nothing sent to the nav agent)"
		}
	}
}

var threePages = []Page{
	{Name: "Kitchen", URL: "http://ha.lan:8123/dashboard-kitchen/lights"},
	{Name: "Weather", URL: "https://www.windy.com"},
	{Name: "Cameras", URL: "http://nvr.lan/live"},
}

// The first page is the device's home: Home goes back to it from anywhere.
func TestHomeGoesToTheFirstPage(t *testing.T) {
	p, nav := navReader(t)
	if err := p.Replace(threePages); err != nil {
		t.Fatal(err)
	}
	p.Next()
	p.Next()
	nav()
	nav()

	p.Home()

	if got := nav(); got != threePages[0].URL {
		t.Errorf("Home navigated to %q, want %q", got, threePages[0].URL)
	}
	if got := p.CurrentLabel(); got != "Kitchen" {
		t.Errorf("current page = %q, want Kitchen", got)
	}
}

// The kiosk starts on the first page, so the current page says so too, and
// the launcher learns where to open without anything sent to the nav agent.
func TestTheKioskStartsOnTheFirstPage(t *testing.T) {
	tempState(t)
	p := NewPages()
	if err := p.Replace(threePages); err != nil {
		t.Fatal(err)
	}
	p.Select("Cameras")

	if got := p.Start(); got != threePages[0].URL {
		t.Errorf("Start = %q, want %q", got, threePages[0].URL)
	}
	if got := p.CurrentLabel(); got != "Kitchen" {
		t.Errorf("current page = %q, want Kitchen", got)
	}
}

// Until Home Assistant sends a list, the one built-in page is Home Assistant
// itself, at the URL it paired with rather than a guessed .local name.
func TestTheBuiltInPageIsHomeAssistantsOwnURL(t *testing.T) {
	tempState(t)
	if got := NewPages().List(); got[0].URL != "http://homeassistant.local:8123" {
		t.Errorf("before pairing: %q, want the .local fallback", got[0].URL)
	}

	if err := writeHAURL("http://192.168.1.5:8123"); err != nil {
		t.Fatal(err)
	}

	if got := NewPages().List(); len(got) != 1 || got[0].URL != "http://192.168.1.5:8123" {
		t.Errorf("after pairing: %v, want Home Assistant's own URL", got)
	}
}
