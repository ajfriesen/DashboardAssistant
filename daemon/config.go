package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// State directory layout (shared group `dashboard`; daemon writes, kiosk reads).
// The base dir is overridable via DASHBOARD_ASSISTANT_STATE_DIR (defaults to the systemd
// StateDirectory); handy for tests and relocating state.
var stateDir = envOr("DASHBOARD_ASSISTANT_STATE_DIR", "/var/lib/dashboard-assistant")

var (
	runtimeEnv   = stateDir + "/runtime.env"
	markerFile   = stateDir + "/provisioned"
	onlineMarker = stateDir + "/online-once"  // set the first time the device is on the network; separates first-connect from a real reconnect
	tokenFile    = stateDir + "/token"        // long-lived HA token for kiosk login injection
	displayFifo  = stateDir + "/display.fifo" // daemon writes on/off; kiosk agent applies via swaymsg
	// Reverse channel: in-session agents write the *actual* power state here and
	// the daemon publishes it, so HA stays in sync with out-of-band changes.
	displayStateFifo = stateDir + "/display-state.fifo"
	apiTokenFile     = stateDir + "/api-token"       // device HA API token, generated on first boot / written by config import
	pairedMarker     = stateDir + "/paired"          // set the first time Home Assistant actually uses the device token; closes the pairing window
	urlsFile         = stateDir + "/urls.json"       // pushable page list (name+url), web UI / config import
	navFifo          = stateDir + "/nav.fifo"        // daemon writes a URL; in-session agent navigates Chromium there
	zoomFifo         = stateDir + "/zoom.fifo"       // daemon writes "zoom <pct>"; in-session agent applies CSS zoom over CDP
	zoomFile         = stateDir + "/zoom"            // persisted browser zoom percent, restored by the kiosk on launch
	themeFifo        = stateDir + "/theme.fifo"      // daemon writes "theme <dark|light>"; in-session agent flips HA's theme over CDP
	themeFile        = stateDir + "/theme"           // persisted dark/light choice, restored by the kiosk on launch
	rotationFifo     = stateDir + "/rotation.fifo"   // daemon writes "rotate <deg>"; in-session agent applies a Sway output transform
	rotationFile     = stateDir + "/rotation"        // persisted display rotation (degrees), restored by the kiosk on launch
	screenshotFifo   = stateDir + "/screenshot.fifo" // daemon pokes it; the in-session grim agent grabs the whole screen
	screenshotFile   = stateDir + "/screenshot.jpg"  // latest whole-screen JPEG written by the grim agent, read back by the daemon
	dmiFile          = stateDir + "/dmi.env"         // hardware serial, written by the daemon's root ExecStartPre (DMI is root-only)
	sendspinFile     = stateDir + "/sendspin"        // persisted on/off for the Sendspin audio player, reapplied to its unit at daemon start
)

const sessionUnit = "greetd.service" // the Sway kiosk session; restart relaunches it

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Provisioned reports whether the device has ever completed setup. Once online,
// it is the sticky bit that separates a never-configured device (SETUP — the
// guided add-to-HA screen) from a configured one (READY). Independent of live
// network state, which deriveState checks first.
func Provisioned() bool {
	_, err := os.Stat(markerFile)
	return err == nil
}

// Paired reports whether Home Assistant has ever used the device API token, and
// so whether the token has already reached the integration. It gates pairing:
// see daemon/pairing.go for why this, and not Provisioned, is the right question.
func Paired() bool {
	_, err := os.Stat(pairedMarker)
	return err == nil
}

func readHAURL() (string, error) {
	f, err := os.Open(runtimeEnv)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "HA_URL=") {
			return strings.Trim(strings.TrimPrefix(line, "HA_URL="), `"`), nil
		}
	}
	return "", sc.Err()
}

// writeHAURL atomically rewrites runtime.env with the given dashboard URL.
// Mode 0664 keeps it readable by the shared `dashboard` group (the kiosk user).
func writeHAURL(url string) error {
	tmp := runtimeEnv + ".tmp"
	content := fmt.Sprintf("HA_URL=%s\n", url)
	if err := os.WriteFile(tmp, []byte(content), 0o664); err != nil {
		return err
	}
	return os.Rename(tmp, runtimeEnv)
}

// parseEnvFile reads a KEY=VALUE file in the systemd EnvironmentFile style: one
// pair per line, `#` comments and blank lines ignored, optional surrounding
// double-quotes stripped. A missing file yields an empty map and no error, so
// callers can treat "not configured yet" the same as "configured empty".
func parseEnvFile(path string) (map[string]string, error) {
	m := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return m, nil
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		m[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"`)
	}
	return m, sc.Err()
}

// writeToken atomically stores the long-lived HA access token. Mode 0640: a
// secret, but readable by the shared `dashboard` group (the kiosk that injects
// it), unlike the group-writable runtime.env.
func writeToken(tok string) error {
	tmp := tokenFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(tok+"\n"), 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, tokenFile)
}

// markProvisioned drops the sticky marker. Also called by the flash-time seed.
func markProvisioned() error {
	return os.WriteFile(markerFile, []byte("1\n"), 0o664)
}

// markPaired records that the device token has been used successfully. Written
// once, from the authenticated API path — never from /api/ha/pair itself, so a
// claim that Home Assistant then fails to act on does not lock the device out.
func markPaired() error {
	return os.WriteFile(pairedMarker, []byte("1\n"), 0o664)
}

// WasOnline reports whether the device has reached the network at least once.
// It separates a fresh, seeded-but-never-online device (which is *connecting*
// for the first time) from a provisioned one that dropped its link (which is
// *reconnecting*), so the waiting splash can say the accurate thing.
func WasOnline() bool {
	_, err := os.Stat(onlineMarker)
	return err == nil
}

// markOnline drops the sticky "has been online" marker, idempotently — cheap to
// call repeatedly since it no-ops once the file exists.
func markOnline() {
	if WasOnline() {
		return
	}
	if err := os.WriteFile(onlineMarker, []byte("1\n"), 0o664); err != nil {
		log.Printf("mark online: %v", err)
	}
}

// clearProvisioningState wipes the device's provisioning + config for a factory
// reset: the HA URL, kiosk login token, provisioned marker, the paired marker,
// the generated device API token (regenerated fresh on the next start), and user
// prefs. Hardware files (dmi.env) and runtime FIFOs are left alone; missing files
// are not an error. The node id (machine-id) is untouched, so Home Assistant sees
// the same device when it is re-added rather than a duplicate.
//
// Dropping the paired marker is what reopens pairing, which is why reset is the
// documented way back for a device that is already in Home Assistant.
func clearProvisioningState() error {
	for _, p := range []string{
		markerFile, runtimeEnv, tokenFile, apiTokenFile, pairedMarker,
		onlineMarker, urlsFile, zoomFile, themeFile, rotationFile,
	} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove %s: %w", filepath.Base(p), err)
		}
	}
	return nil
}

// forgetWifi deletes every saved Wi-Fi profile, so a factory-reset device comes
// back onboardable rather than silently rejoining the network it was reset away
// from. Without it, "reset the tablet, then take it to a different house" quietly
// does not work: the old profile autoconnects, the device never looks stranded,
// and the setup AP never appears.
//
// The AP passphrase file is deliberately *not* removed. It may be on a printed
// label or in a photo, and rotating a credential whose only job is to be readable
// off the screen of the device it protects buys nothing.
func forgetWifi(nm *NetworkManager) error {
	if nm == nil {
		return nil
	}
	return nm.ForgetWifiProfiles()
}

var (
	kioskRestartMu     sync.Mutex
	lastKioskRestart   time.Time
	kioskRestartQueued bool

	// Window in which a second restart is folded into the first. A var, not a
	// const, so tests can shrink it.
	kioskRestartWindow = 8 * time.Second

	// The actual session restart, swapped out in tests. Nothing else should call
	// it directly: restartKiosk owns the coalescing.
	kioskRestartFn = restartSessionUnit
)

// restartKiosk restarts the greetd session, coalescing bursts. A single
// provisioning event can trigger two restart paths almost at once: kiosk_login
// (or config import) staging the login, and the READY-transition watcher reacting
// to the same SETUP to READY flip. Restarting twice tears the session down
// mid-autologin, so calls inside the window collapse into one.
//
// It defers rather than drops. Discarding the later call loses whatever state
// change prompted it: a token staged a second after an unrelated restart would
// never reach the session, and the device sits on the login screen until someone
// reboots it. So the last caller in a burst is honoured, just late.
func restartKiosk() error {
	kioskRestartMu.Lock()
	if wait := kioskRestartWindow - time.Since(lastKioskRestart); wait > 0 {
		if kioskRestartQueued {
			kioskRestartMu.Unlock()
			log.Printf("kiosk: restart already queued; coalesced")
			return nil
		}
		kioskRestartQueued = true
		kioskRestartMu.Unlock()
		log.Printf("kiosk: restart deferred %s so it does not land mid-autologin", wait.Round(time.Second))
		// Slack past the window so the retry cannot re-defer on a boundary.
		time.AfterFunc(wait+100*time.Millisecond, func() {
			kioskRestartMu.Lock()
			kioskRestartQueued = false
			kioskRestartMu.Unlock()
			if err := restartKiosk(); err != nil {
				log.Printf("kiosk: deferred restart: %v", err)
			}
		})
		return nil
	}
	lastKioskRestart = time.Now()
	kioskRestartMu.Unlock()
	return kioskRestartFn()
}

// restartSessionUnit restarts greetd over the systemd D-Bus API. A scoped polkit
// rule (see daemon.nix) grants dashboard-assistant rights to manage only this
// unit. Restarting re-runs the state-aware launcher, which re-reads /api/state.
func restartSessionUnit() error {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("connect system bus: %w", err)
	}
	defer conn.Close()

	systemd := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	var job dbus.ObjectPath
	err = systemd.Call("org.freedesktop.systemd1.Manager.RestartUnit", 0,
		sessionUnit, "replace").Store(&job)
	if err != nil {
		return fmt.Errorf("RestartUnit %s: %w", sessionUnit, err)
	}
	return nil
}

// bootGeneration triggers a rollback+reboot into NixOS generation n by starting
// the templated dashboard-assistant-rollback@<n>.service (which switches the profile, runs the
// generation's switch-to-configuration boot, and reboots — all as root). A
// scoped polkit rule grants dashboard-assistant rights to start just these units. The
// number is validated by the caller and re-checked by the unit's script.
func bootGeneration(n int) error {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("connect system bus: %w", err)
	}
	defer conn.Close()

	unit := fmt.Sprintf("dashboard-assistant-rollback@%d.service", n)
	systemd := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	var job dbus.ObjectPath
	err = systemd.Call("org.freedesktop.systemd1.Manager.StartUnit", 0, unit, "replace").Store(&job)
	if err != nil {
		return fmt.Errorf("StartUnit %s: %w", unit, err)
	}
	return nil
}

// refPattern bounds the release tag we interpolate into the dashboard-assistant-update@ instance
// name (and, in the unit's script, into the flake ref). Tags are validated here
// and re-validated by the script.
var refPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// startUpdate applies an OS update to release ref (a git tag) by starting the
// templated, root-run dashboard-assistant-update@<ref>.service, which does the flake
// `nixos-rebuild switch`. A scoped polkit rule grants dashboard-assistant rights to
// start just these units.
//
// It watches the start job over D-Bus and calls onDone with the job result once
// the rebuild finishes ("done" on success, e.g. "failed" otherwise). A
// successful switch usually restarts the daemon, so onDone may never fire — the
// fresh process republishes clean state instead; that's expected.
func startUpdate(ref string, onDone func(result string)) error {
	if !refPattern.MatchString(ref) {
		return fmt.Errorf("invalid ref: %q", ref)
	}
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("connect system bus: %w", err)
	}

	systemd := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	// systemd only emits job/unit signals to clients that have subscribed.
	if call := systemd.Call("org.freedesktop.systemd1.Manager.Subscribe", 0); call.Err != nil {
		conn.Close()
		return fmt.Errorf("subscribe: %w", call.Err)
	}
	if err := conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.systemd1.Manager"),
		dbus.WithMatchMember("JobRemoved"),
	); err != nil {
		conn.Close()
		return fmt.Errorf("add match: %w", err)
	}
	ch := make(chan *dbus.Signal, 16)
	conn.Signal(ch)

	unit := fmt.Sprintf("dashboard-assistant-update@%s.service", ref)
	var job dbus.ObjectPath
	if err := systemd.Call("org.freedesktop.systemd1.Manager.StartUnit", 0, unit, "replace").Store(&job); err != nil {
		conn.Close()
		return fmt.Errorf("StartUnit %s: %w", unit, err)
	}

	go func() {
		defer conn.Close()
		// JobRemoved signature: (u id, o job, s unit, s result).
		for sig := range ch {
			if sig.Name != "org.freedesktop.systemd1.Manager.JobRemoved" || len(sig.Body) < 4 {
				continue
			}
			if jobPath, _ := sig.Body[1].(dbus.ObjectPath); jobPath != job {
				continue
			}
			result, _ := sig.Body[3].(string)
			onDone(result)
			return
		}
	}()
	return nil
}

// ensureStateDir makes sure the state directory exists (systemd StateDirectory
// normally handles this; belt-and-suspenders for direct runs).
func ensureStateDir() error {
	return os.MkdirAll(filepath.Dir(runtimeEnv), 0o775)
}
