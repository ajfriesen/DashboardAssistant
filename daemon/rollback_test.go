package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// fakeSystems builds a throwaway stand-in for the three things that tell this
// device what it booted: the NixOS system profile and the /run/{booted,current}-system
// symlinks. Each generation gets a closure with the baked-in version file the
// update module writes, so a rejected release can be named rather than guessed.
//
// Paths are swapped the same way btrfs_test.go and update_test.go swap theirs.
func fakeSystems(t *testing.T, versions map[int]string) string {
	t.Helper()
	dir := t.TempDir()
	profiles := filepath.Join(dir, "profiles")
	if err := os.MkdirAll(profiles, 0o755); err != nil {
		t.Fatal(err)
	}
	for n, v := range versions {
		closure := filepath.Join(dir, "store", "system-"+strconv.Itoa(n))
		if err := os.MkdirAll(filepath.Join(closure, "etc", "dashboard-assistant"), 0o755); err != nil {
			t.Fatal(err)
		}
		if v != "" {
			if err := os.WriteFile(filepath.Join(closure, "etc", "dashboard-assistant", "version"), []byte(v+"\n"), 0o444); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.Symlink(closure, filepath.Join(profiles, "system-"+strconv.Itoa(n)+"-link")); err != nil {
			t.Fatal(err)
		}
	}

	origProfile, origBooted, origCurrent := systemProfile, bootedSystemLink, currentSystemLink
	systemProfile = filepath.Join(profiles, "system")
	bootedSystemLink = filepath.Join(dir, "booted-system")
	currentSystemLink = filepath.Join(dir, "current-system")
	t.Cleanup(func() {
		systemProfile, bootedSystemLink, currentSystemLink = origProfile, origBooted, origCurrent
	})
	return dir
}

// point aims the profile symlink and the two /run links at generations, the way
// a running system does: the profile at the generation that was *switched to*,
// booted at the one the bootloader actually started, current at the activated one.
func point(t *testing.T, dir string, profile, booted, current int) {
	t.Helper()
	for link, gen := range map[string]int{
		systemProfile:     profile,
		bootedSystemLink:  booted,
		currentSystemLink: current,
	} {
		if gen == 0 {
			continue
		}
		target := filepath.Join(dir, "profiles", "system-"+strconv.Itoa(gen)+"-link")
		if link != systemProfile {
			// /run/{booted,current}-system point straight at the closure, not
			// through the numbered profile link.
			target = filepath.Join(dir, "store", "system-"+strconv.Itoa(gen))
		}
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}
}

// A boot-counting rollback is the one case where the system profile and the
// booted system disagree *after* a boot: systemd-boot picked the older entry on
// its own, and nothing moved the profile back. The release the device refused is
// the one in the generation the profile still points at.
func TestRollbackNamesTheRejectedRelease(t *testing.T) {
	dir := fakeSystems(t, map[int]string{1: "1.4.0", 2: "1.5.0"})
	point(t, dir, 2, 1, 1)

	got := detectRollback()
	if !got.Happened {
		t.Fatalf("detectRollback() = %+v, want a rollback: generation 2 was switched to but generation 1 booted", got)
	}
	if got.Version != "1.5.0" {
		t.Errorf("rejected version = %q, want 1.5.0 (the generation the profile points at)", got.Version)
	}
	if got.Generation != 2 {
		t.Errorf("rejected generation = %d, want 2", got.Generation)
	}
}

// The states that look like a rollback and are not. The pending-switch case is
// the dangerous one: an update that has activated but not rebooted leaves the
// profile and the booted system disagreeing exactly as a rollback does, and
// calling it a rollback would reject the release the device is about to boot.
func TestNoRollbackOnTheLookAlikeStates(t *testing.T) {
	for name, state := range map[string]struct{ profile, booted, current int }{
		"an ordinary boot":                  {1, 1, 1},
		"a good boot after an update":       {2, 2, 2},
		"an update switched, not rebooted":  {2, 1, 2},
		"a manual rollback, already booted": {1, 1, 1},
	} {
		t.Run(name, func(t *testing.T) {
			dir := fakeSystems(t, map[int]string{1: "1.4.0", 2: "1.5.0"})
			point(t, dir, state.profile, state.booted, state.current)

			if got := detectRollback(); got.Happened {
				t.Fatalf("detectRollback() = %+v during %s, want no rollback", got, name)
			}
		})
	}
}

// A device that is not NixOS at all — a developer running the daemon from source
// — has none of the three symlinks. That has to read as "no rollback" rather
// than as an unnameable one, or every source build would report a rejected
// release to Home Assistant.
func TestNoRollbackWithoutASystemProfile(t *testing.T) {
	fakeSystems(t, nil)

	if got := detectRollback(); got.Happened {
		t.Fatalf("detectRollback() = %+v with no profile, want no rollback", got)
	}
}

// A generation built before the version file existed can still be rolled back
// from. The rollback must be reported; only its name is missing.
func TestRollbackFromAGenerationWithNoVersionFile(t *testing.T) {
	dir := fakeSystems(t, map[int]string{1: "1.4.0", 2: ""})
	point(t, dir, 2, 1, 1)

	got := detectRollback()
	if !got.Happened || got.Version != "" {
		t.Fatalf("detectRollback() = %+v, want a rollback with no version", got)
	}
}
