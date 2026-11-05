package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
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
