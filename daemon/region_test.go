package main

import (
	"errors"
	"os"
	"testing"
)

// newTestRegion records what Region would ask of timedated and the kiosk.
func newTestRegion(t *testing.T) (r *Region, timezones *[]string, relaunches *int) {
	t.Helper()
	tempState(t)
	r = NewRegion()
	timezones, relaunches = &[]string{}, new(int)
	r.setTimezone = func(tz string) error { *timezones = append(*timezones, tz); return nil }
	r.relaunch = func() error { *relaunches++; return nil }
	return r, timezones, relaunches
}

func TestRegionDefaultsToUTCAndEnglish(t *testing.T) {
	r, _, _ := newTestRegion(t)
	if got := r.Prefs(); got != defaultRegion {
		t.Fatalf("Prefs = %+v, want %+v", got, defaultRegion)
	}
}

// The timezone goes to the system, the locale relaunches the kiosk, and both
// survive a daemon restart.
func TestRegionSetAppliesAndPersists(t *testing.T) {
	r, timezones, relaunches := newTestRegion(t)

	if err := r.Set(RegionPrefs{Timezone: " Europe/Berlin ", Locale: "de_DE"}); err != nil {
		t.Fatalf("Set: %v", err)
	}
	want := RegionPrefs{Timezone: "Europe/Berlin", Locale: "de-DE"}
	if got := r.Prefs(); got != want {
		t.Fatalf("Prefs = %+v, want %+v", got, want)
	}
	if len(*timezones) != 1 || (*timezones)[0] != "Europe/Berlin" {
		t.Fatalf("timezones set = %v, want [Europe/Berlin]", *timezones)
	}
	if *relaunches != 1 {
		t.Fatalf("relaunches = %d, want 1", *relaunches)
	}
	if got := loadRegion(); got != want {
		t.Fatalf("persisted = %+v, want %+v", got, want)
	}
}

// Only what changed is applied: a timezone change must not relaunch the kiosk
// under the user, and sending the same prefs again does nothing.
func TestRegionSetAppliesOnlyWhatChanged(t *testing.T) {
	r, timezones, relaunches := newTestRegion(t)

	if err := r.Set(RegionPrefs{Timezone: "America/New_York", Locale: "en-US"}); err != nil {
		t.Fatal(err)
	}
	if len(*timezones) != 1 || *relaunches != 0 {
		t.Fatalf("timezone change: %d timezone calls, %d relaunches; want 1, 0", len(*timezones), *relaunches)
	}
	if err := r.Set(RegionPrefs{Timezone: "America/New_York", Locale: "en-US"}); err != nil {
		t.Fatal(err)
	}
	if len(*timezones) != 1 || *relaunches != 0 {
		t.Fatalf("same prefs again: %d timezone calls, %d relaunches; want 1, 0", len(*timezones), *relaunches)
	}
}

func TestRegionSetRefusesWhatItCannotUse(t *testing.T) {
	for _, p := range []RegionPrefs{
		{Timezone: "Mars/Olympus_Mons", Locale: "en-US"},
		{Timezone: "", Locale: "en-US"},
		{Timezone: "Local", Locale: "en-US"},
		{Timezone: "UTC", Locale: ""},
		{Timezone: "UTC", Locale: "not a locale"},
	} {
		t.Run(p.Timezone+"/"+p.Locale, func(t *testing.T) {
			r, timezones, relaunches := newTestRegion(t)
			err := r.Set(p)
			if !errors.Is(err, errBadRegion) {
				t.Fatalf("Set(%+v) = %v, want errBadRegion", p, err)
			}
			if r.Prefs() != defaultRegion || len(*timezones) != 0 || *relaunches != 0 {
				t.Fatalf("a refused Set changed something")
			}
			if _, err := os.Stat(regionFile); !os.IsNotExist(err) {
				t.Fatalf("a refused Set wrote region.json")
			}
		})
	}
}

// If timedated refuses, nothing is saved, so the device never reports a
// timezone it is not on.
func TestRegionSetKeepsOldPrefsWhenTheTimezoneFails(t *testing.T) {
	r, _, relaunches := newTestRegion(t)
	r.setTimezone = func(string) error { return errors.New("access denied") }

	if err := r.Set(RegionPrefs{Timezone: "Europe/Berlin", Locale: "de-DE"}); err == nil || errors.Is(err, errBadRegion) {
		t.Fatalf("Set = %v, want the timedated error", err)
	}
	if r.Prefs() != defaultRegion || *relaunches != 0 {
		t.Fatalf("a failed Set changed something: %+v, %d relaunches", r.Prefs(), *relaunches)
	}
}

// Reconcile puts the system on the saved timezone, and on UTC once a factory
// reset has removed region.json.
func TestRegionReconcileAppliesTheSavedTimezone(t *testing.T) {
	r, timezones, _ := newTestRegion(t)
	if err := r.Set(RegionPrefs{Timezone: "Asia/Tokyo", Locale: "ja"}); err != nil {
		t.Fatal(err)
	}
	if err := clearProvisioningState(); err != nil {
		t.Fatal(err)
	}
	*timezones = nil
	r = NewRegion()
	r.setTimezone = func(tz string) error { *timezones = append(*timezones, tz); return nil }
	r.Reconcile()
	if len(*timezones) != 1 || (*timezones)[0] != "UTC" {
		t.Fatalf("after a reset, timezones set = %v, want [UTC]", *timezones)
	}
}

// A hand-edited or half-written file falls back field by field.
func TestRegionLoadFallsBackPerField(t *testing.T) {
	tempState(t)
	if err := os.WriteFile(regionFile, []byte(`{"timezone":"Europe/Paris","locale":"???"}`), 0o664); err != nil {
		t.Fatal(err)
	}
	want := RegionPrefs{Timezone: "Europe/Paris", Locale: "en-US"}
	if got := loadRegion(); got != want {
		t.Fatalf("loadRegion = %+v, want %+v", got, want)
	}
}
