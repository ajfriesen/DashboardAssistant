package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
	_ "time/tzdata" // validate timezone names without depending on the host's zoneinfo

	"github.com/godbus/dbus/v5"
)

// RegionPrefs is the device's timezone and locale, which Home Assistant sets
// from its own settings. Timezone is an IANA name ("Europe/Berlin"); Locale is
// a BCP 47 language tag ("de-DE"). Both always hold a value: a device Home
// Assistant has not set them on reports the defaults.
type RegionPrefs struct {
	Timezone string `json:"timezone"`
	Locale   string `json:"locale"`
}

var defaultRegion = RegionPrefs{Timezone: "UTC", Locale: "en-US"}

// errBadRegion marks a request the device refuses, as opposed to one it failed
// to apply, so the API can answer 400 rather than 500.
var errBadRegion = errors.New("invalid region")

// localeTag is a loose BCP 47 check: a language, then optional script, region
// or variant subtags. Loose on purpose: Chromium falls back to English for a
// tag it has no translation for, so the device only refuses what is not a tag.
var localeTag = regexp.MustCompile(`^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$`)

// Region holds the timezone and locale and applies them. The timezone goes to
// systemd-timedated, which rewrites /etc/localtime; Chromium watches that file
// and follows without a restart. The locale is read by the kiosk launcher
// (kiosk.nix) when it starts Chromium, so changing it relaunches the kiosk.
// region.json is the one copy: Reconcile re-applies the timezone from it on
// every start, so a factory reset, which deletes it, puts the device back on UTC.
type Region struct {
	// apply serialises everything that changes the system timezone, so Set and
	// Reconcile cannot interleave and leave the system on a zone the device does
	// not report. mu guards the fields and is never held across D-Bus, so a slow
	// timedated does not stall Prefs and with it every state snapshot.
	apply    sync.Mutex
	mu       sync.Mutex
	prefs    RegionPrefs
	applied  bool // the system is known to be on prefs.Timezone
	observer func()

	// Swapped out in tests.
	setTimezone func(string) error
	relaunch    func() error
}

// NewRegion loads the persisted prefs, falling back to the defaults.
func NewRegion() *Region {
	return &Region{
		prefs:       loadRegion(),
		setTimezone: setSystemTimezone,
		relaunch:    restartKiosk,
	}
}

// SetObserver registers a callback fired (outside the lock) after any change, so
// the HA hub can broadcast the state.
func (r *Region) SetObserver(f func()) {
	r.mu.Lock()
	r.observer = f
	r.mu.Unlock()
}

// Prefs returns the current timezone and locale.
// A nil Region reports the defaults: the hub's observers can broadcast before
// main hands it one.
func (r *Region) Prefs() RegionPrefs {
	if r == nil {
		return defaultRegion
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.prefs
}

// Set validates, applies and persists new prefs. On a refused or failed
// timezone nothing changes. A locale change relaunches the kiosk so Chromium
// starts in the new language; if that fails, the next launch picks it up.
// Sending the same prefs again re-applies the timezone if the system is not
// known to be on it, so Home Assistant can repair a failed Reconcile.
func (r *Region) Set(p RegionPrefs) error {
	p, err := cleanRegion(p)
	if err != nil {
		return err
	}

	r.apply.Lock()
	r.mu.Lock()
	old, applied := r.prefs, r.applied
	r.mu.Unlock()
	if p == old && applied {
		r.apply.Unlock()
		return nil
	}
	tzChanged := p.Timezone != old.Timezone || !applied
	if tzChanged {
		if err := r.setTimezone(p.Timezone); err != nil {
			r.apply.Unlock()
			return err
		}
	}
	if err := saveRegion(p); err != nil {
		if tzChanged {
			// The system is on p.Timezone, the device still reports old.
			r.mu.Lock()
			r.applied = false
			r.mu.Unlock()
		}
		r.apply.Unlock()
		return err
	}
	r.mu.Lock()
	r.prefs, r.applied = p, true
	obs := r.observer
	r.mu.Unlock()
	r.apply.Unlock()

	if p.Locale != old.Locale {
		if err := r.relaunch(); err != nil {
			log.Printf("region: relaunch kiosk for locale %s: %v", p.Locale, err)
		}
	}
	if obs != nil {
		obs()
	}
	return nil
}

// Reconcile applies the persisted timezone to the system, for a device whose
// /etc/localtime does not match region.json: after a factory reset, or on the
// first start of a build that has this. timedated makes it a no-op when it
// already matches.
func (r *Region) Reconcile() {
	r.apply.Lock()
	defer r.apply.Unlock()
	tz := r.Prefs().Timezone
	if err := r.setTimezone(tz); err != nil {
		log.Printf("region: apply timezone %s: %v", tz, err)
		return
	}
	r.mu.Lock()
	r.applied = true
	r.mu.Unlock()
}

// cleanRegion trims and checks the prefs, writing the locale in canonical form.
func cleanRegion(p RegionPrefs) (RegionPrefs, error) {
	p.Timezone = strings.TrimSpace(p.Timezone)
	p.Locale = strings.ReplaceAll(strings.TrimSpace(p.Locale), "_", "-")
	if !validTimezone(p.Timezone) {
		return p, fmt.Errorf("%w: timezone %q is not an IANA timezone", errBadRegion, p.Timezone)
	}
	if !localeTag.MatchString(p.Locale) {
		return p, fmt.Errorf("%w: locale %q is not a language tag", errBadRegion, p.Locale)
	}
	p.Locale = canonicalLocale(p.Locale)
	return p, nil
}

// canonicalLocale writes a tag in BCP 47's conventional case: a lowercase
// language, a title-case script, an uppercase region ("zh-Hans-CN"). The kiosk
// maps the language to a keyboard and Chromium locale with a case-sensitive
// match, so "DE-de" has to arrive as "de-DE".
func canonicalLocale(tag string) string {
	sub := strings.Split(strings.ToLower(tag), "-")
	for i := 1; i < len(sub); i++ {
		switch s := sub[i]; {
		case len(s) == 4 && s[0] >= 'a':
			sub[i] = strings.ToUpper(s[:1]) + s[1:]
		case len(s) == 2 && s[0] >= 'a':
			sub[i] = strings.ToUpper(s)
		}
	}
	return strings.Join(sub, "-")
}

// validTimezone reports whether tz names an IANA zone. LoadLocation also
// accepts "" and "Local", which name none.
func validTimezone(tz string) bool {
	if tz == "" || tz == "Local" {
		return false
	}
	_, err := time.LoadLocation(tz)
	return err == nil
}

// setSystemTimezone asks systemd-timedated to switch the system timezone. A
// scoped polkit rule (daemon.nix) lets the daemon do only this, and
// time.timeZone = null (default.nix) is what lets timedated change it at all.
func setSystemTimezone(tz string) error {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("connect system bus: %w", err)
	}
	defer conn.Close()
	obj := conn.Object("org.freedesktop.timedate1", "/org/freedesktop/timedate1")
	if err := obj.Call("org.freedesktop.timedate1.SetTimezone", 0, tz, false).Err; err != nil {
		return fmt.Errorf("SetTimezone %s: %w", tz, err)
	}
	return nil
}

// loadRegion reads region.json, falling back to the defaults for a missing or
// unreadable file and for any field it lacks.
func loadRegion() RegionPrefs {
	p := defaultRegion
	b, err := os.ReadFile(regionFile)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("region: load %s: %v", regionFile, err)
		}
		return p
	}
	var saved RegionPrefs
	if err := json.Unmarshal(b, &saved); err != nil {
		log.Printf("region: load %s: %v", regionFile, err)
		return p
	}
	if validTimezone(saved.Timezone) {
		p.Timezone = saved.Timezone
	}
	if localeTag.MatchString(saved.Locale) {
		p.Locale = saved.Locale
	}
	return p
}

// saveRegion atomically persists the prefs. Mode 0664: the kiosk launcher reads
// the locale through the shared group, like urls.json.
func saveRegion(p RegionPrefs) error {
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(regionFile, append(b, '\n'), 0o664)
}
