package main

// Did this boot roll back?
//
// Automatic rollback (docs/adr/0009) is systemd-boot's job: it writes a new
// generation's boot entry with a counter, decrements it on every attempt, and
// once the counter reaches zero boots the previous entry instead. Nothing tells
// the daemon that happened — there is no file and no unit, because the component
// that made the decision is the bootloader, two stages before userland.
//
// So it is derived, from three symlinks the running system already maintains:
//
//	/nix/var/nix/profiles/system   the generation that was last *switched to*
//	/run/booted-system             the generation the bootloader actually started
//	/run/current-system            the generation whose activation is live
//
// On an ordinary boot all three agree. The two interesting disagreements are:
//
//	profile == current != booted    an update switched but has not rebooted yet
//	profile != current == booted    the bootloader abandoned the profile's
//	                                generation and came up on an older one
//
// The second is a rollback, and the release the device refused is the one baked
// into the generation the profile still points at — not the running version,
// which is the release the device fell *back* to. Telling the two apart is the
// whole reason current-system is read as well as booted-system: immediately
// after an update switches, the profile and the booted system also disagree, and
// reading only those two would report every pending update as a rollback.
//
// Nothing is persisted, deliberately. The profile keeps pointing at the rejected
// generation until the next update switches, which is exactly as long as the
// rejection is supposed to last ("skips it until a newer one ships") — so a
// marker file would be a second copy of a fact the system already states, with
// its own ways of going stale.

import (
	"log"
	"os"
	"path/filepath"
	"strings"
)

// Where the running system records what it booted and what is activated. Vars
// rather than consts so rollback_test.go can point them at a fake tree.
var (
	bootedSystemLink  = "/run/booted-system"
	currentSystemLink = "/run/current-system"
)

// Rollback is what an automatic rollback left behind. The zero value means this
// boot is an ordinary one — which is also what an undeterminable answer looks
// like, so a missing symlink or an unreadable profile never invents a rollback.
type Rollback struct {
	Happened bool
	// Version of the rejected release, from the generation's own baked-in
	// version file. Empty when that generation predates the file, which is the
	// only case where a rollback is known to have happened but cannot be named.
	Version string
	// Generation that failed to reach a good boot, for the log and the admin page.
	Generation int
}

// detectRollback answers whether the bootloader abandoned the generation this
// device last switched to. See the file header for why it is three symlinks.
func detectRollback() Rollback {
	profile := resolveSystem(systemProfile)
	booted := resolveSystem(bootedSystemLink)
	current := resolveSystem(currentSystemLink)
	// Anything unreadable: say nothing. On a non-NixOS host (a developer running
	// the daemon straight from source) none of the three exist.
	if profile == "" || booted == "" || current == "" {
		return Rollback{}
	}
	// The profile is what the device chose; agreement means nothing overrode it.
	if profile == booted {
		return Rollback{}
	}
	// A switch that has not rebooted yet: the new generation is activated and
	// running, the old one is merely what the bootloader started. Not a rollback.
	if current != booted {
		return Rollback{}
	}
	return Rollback{
		Happened:   true,
		Version:    generationVersion(systemProfile),
		Generation: currentGeneration(),
	}
}

// resolveSystem follows a system symlink all the way to its store path, so the
// three links compare by what they point at rather than by how they spell it:
// the profile goes through a numbered "-N-link" hop that /run/booted-system does
// not. "" when the link is missing or dangling.
func resolveSystem(link string) string {
	target, err := filepath.EvalSymlinks(link)
	if err != nil {
		return ""
	}
	return target
}

// generationVersion reads the release version baked into a generation's closure
// by the update module (environment.etc."dashboard-assistant/version"). Reading it out of
// the closure rather than parsing config.system.nixos.label is what makes a
// prerelease nameable: a label is tags and nixpkgs version joined by hyphens, so
// "dashboard-assistant-1.6.0-rc1-26.11…" cannot be split back apart reliably.
func generationVersion(link string) string {
	b, err := os.ReadFile(filepath.Join(link, "etc", "dashboard-assistant", "version"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// logRollback puts a detected rollback in the journal once, at startup. The
// journal is volatile on this appliance (flash-wear.nix), so this is a breadcrumb
// for whoever is looking at a live device, not the record — the record is the
// state the daemon reports to Home Assistant.
func logRollback(r Rollback) {
	if !r.Happened {
		return
	}
	version := r.Version
	if version == "" {
		version = "an unnamed release"
	}
	log.Printf("update: this device rolled back from %s (generation %d never reached a good boot); skipping that release until a newer one ships",
		version, r.Generation)
}
