package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func timezoneRequest(h *HAHub, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/ha/timezone", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.routes().ServeHTTP(rec, req)
	return rec
}

// stubTimezone replaces the timedated call for one test and records what it was
// asked to set.
func stubTimezone(t *testing.T, err error) *[]string {
	t.Helper()
	var got []string
	prev := applyTimezone
	applyTimezone = func(name string) error {
		got = append(got, name)
		return err
	}
	t.Cleanup(func() { applyTimezone = prev })
	return &got
}

// Home Assistant pushes its own zone so the clock screen saver, and any
// dashboard that formats times in the browser, shows local time.
func TestHomeAssistantSetsTheTimezone(t *testing.T) {
	tempState(t)
	got := stubTimezone(t, nil)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	rec := timezoneRequest(h, "tok", `{"timezone": "Europe/Berlin"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("set timezone = %d, want %d (%s)", rec.Code, http.StatusOK, rec.Body)
	}
	if len(*got) != 1 || (*got)[0] != "Europe/Berlin" {
		t.Fatalf("applied %v, want [Europe/Berlin]", *got)
	}
}

func TestTimezoneIsBehindTheDeviceToken(t *testing.T) {
	tempState(t)
	got := stubTimezone(t, nil)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	if rec := timezoneRequest(h, "", `{"timezone": "Europe/Berlin"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("set timezone without a token = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
	if len(*got) != 0 {
		t.Fatalf("applied %v without a token", *got)
	}
}

// Only names from the tz database reach timedated; anything else is the
// caller's mistake, not a failure on the device.
func TestTimezoneRejectsNamesOutsideTheTzDatabase(t *testing.T) {
	tempState(t)
	got := stubTimezone(t, nil)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	for _, name := range []string{"", "Mars/Olympus_Mons", "../../etc/passwd", "Local", "/Europe/Berlin"} {
		rec := timezoneRequest(h, "tok", `{"timezone": "`+name+`"}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("timezone %q = %d, want %d", name, rec.Code, http.StatusBadRequest)
		}
	}
	if len(*got) != 0 {
		t.Fatalf("applied %v, want nothing", *got)
	}
}

func TestTimezoneReportsAFailureToApplyIt(t *testing.T) {
	tempState(t)
	stubTimezone(t, errors.New("access denied"))
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	if rec := timezoneRequest(h, "tok", `{"timezone": "Europe/Berlin"}`); rec.Code < 500 {
		t.Fatalf("set timezone with timedated refusing = %d, want a 5xx", rec.Code)
	}
}
