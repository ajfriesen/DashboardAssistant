package main

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
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

// If applying the timezone at start failed, Home Assistant sending the same
// prefs again must apply it, not be skipped as "nothing changed".
func TestRegionSetReappliesAfterAFailedReconcile(t *testing.T) {
	r, timezones, _ := newTestRegion(t)
	if err := r.Set(RegionPrefs{Timezone: "Asia/Tokyo", Locale: "en-US"}); err != nil {
		t.Fatal(err)
	}
	r = NewRegion()
	r.setTimezone = func(string) error { return errors.New("timedated not ready") }
	r.Reconcile()

	*timezones = nil
	r.setTimezone = func(tz string) error { *timezones = append(*timezones, tz); return nil }
	if err := r.Set(RegionPrefs{Timezone: "Asia/Tokyo", Locale: "en-US"}); err != nil {
		t.Fatal(err)
	}
	if len(*timezones) != 1 || (*timezones)[0] != "Asia/Tokyo" {
		t.Fatalf("timezones set = %v, want [Asia/Tokyo]", *timezones)
	}
}

// If the system took the new timezone but region.json could not be written,
// sending the old prefs again must put the system back on them.
func TestRegionSetReappliesAfterAFailedSave(t *testing.T) {
	r, timezones, _ := newTestRegion(t)
	dir := filepath.Dir(regionFile)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	if err := r.Set(RegionPrefs{Timezone: "Europe/Berlin", Locale: "en-US"}); err == nil {
		t.Fatal("Set with an unwritable state dir succeeded")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}

	*timezones = nil
	if err := r.Set(defaultRegion); err != nil {
		t.Fatal(err)
	}
	if len(*timezones) != 1 || (*timezones)[0] != "UTC" {
		t.Fatalf("timezones set = %v, want [UTC]", *timezones)
	}
}

// Reconcile at start can overlap a Set from Home Assistant. Whatever lands on
// the system last must be what the device reports.
func TestRegionReconcileCannotUndoAConcurrentSet(t *testing.T) {
	r, _, _ := newTestRegion(t)
	var mu sync.Mutex
	var landed []string
	started, release := make(chan struct{}), make(chan struct{})
	first := true
	r.setTimezone = func(tz string) error {
		mu.Lock()
		block := first
		first = false
		mu.Unlock()
		if block {
			close(started)
			<-release
		}
		mu.Lock()
		landed = append(landed, tz)
		mu.Unlock()
		return nil
	}

	done := make(chan struct{})
	go func() { r.Reconcile(); close(done) }()
	<-started
	setDone := make(chan error)
	go func() { setDone <- r.Set(RegionPrefs{Timezone: "Europe/Berlin", Locale: "en-US"}) }()
	time.Sleep(50 * time.Millisecond)
	close(release)
	<-done
	if err := <-setDone; err != nil {
		t.Fatal(err)
	}

	if last := landed[len(landed)-1]; last != r.Prefs().Timezone {
		t.Fatalf("system ended on %s, device reports %s (landed %v)", last, r.Prefs().Timezone, landed)
	}
}

// A slow timedated must not stall the state snapshot, which reads Prefs.
func TestRegionPrefsDoesNotWaitForTimedated(t *testing.T) {
	r, _, _ := newTestRegion(t)
	started, release := make(chan struct{}), make(chan struct{})
	r.setTimezone = func(string) error { close(started); <-release; return nil }
	setDone := make(chan struct{})
	go func() { r.Set(RegionPrefs{Timezone: "Europe/Berlin", Locale: "en-US"}); close(setDone) }()
	<-started
	defer func() { close(release); <-setDone }()

	got := make(chan RegionPrefs)
	go func() { got <- r.Prefs() }()
	select {
	case <-got:
	case <-time.After(time.Second):
		t.Fatal("Prefs blocked while timedated was applying a timezone")
	}
}

// Tags are stored in their canonical case, so the kiosk's keyboard and
// language mapping, which matches lowercase languages, sees them.
func TestRegionSetCanonicalisesLocaleCase(t *testing.T) {
	for in, want := range map[string]string{
		"DE-de":      "de-DE",
		"De":         "de",
		"zh-hans-cn": "zh-Hans-CN",
		"SR_LATN":    "sr-Latn",
		"es-419":     "es-419",
	} {
		r, _, _ := newTestRegion(t)
		if err := r.Set(RegionPrefs{Timezone: "UTC", Locale: in}); err != nil {
			t.Fatalf("Set(%q): %v", in, err)
		}
		if got := r.Prefs().Locale; got != want {
			t.Errorf("Set(%q) stored %q, want %q", in, got, want)
		}
	}
}

// The hub's observers can broadcast before main hands it the Region.
func TestRegionPrefsOnNilRegionReportsDefaults(t *testing.T) {
	var r *Region
	if got := r.Prefs(); got != defaultRegion {
		t.Fatalf("Prefs = %+v, want %+v", got, defaultRegion)
	}
}
