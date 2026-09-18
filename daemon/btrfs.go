package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// btrfs root-filesystem health, read entirely from world-readable sysfs and
// procfs — the daemon has no CAP_SYS_ADMIN (NoNewPrivileges in daemon.nix), so
// the btrfs ioctls behind `btrfs device stats` / `scrub status` are out of
// reach. The kernel keeps the same per-device error counters in
// /sys/fs/btrfs/<fsid>/devinfo/<devid>/error_stats, and a scrub that finds
// problems bumps those very counters (the monthly timer is wired up in
// modules/core/btrfs-maintenance.nix). The other high-value signal is the
// filesystem having been forced read-only, which btrfs does on serious errors.

// Swappable for tests, like stateDir (update_test.go).
//
// PID 1's mount table, not our own: the daemon runs under
// ProtectSystem=strict, so in its private mount namespace / is a read-only
// remount and /proc/self/mounts would report "ro" on every healthy system.
// /proc/1/mounts shows the host's real state and is world-readable.
var (
	btrfsSysfsRoot = "/sys/fs/btrfs"
	procMountsPath = "/proc/1/mounts"
)

type btrfsHealth struct {
	Readonly       bool
	WriteErrs      int
	ReadErrs       int
	FlushErrs      int
	CorruptionErrs int
	GenerationErrs int
	Devices        int
}

// readBtrfsHealth probes the btrfs filesystem backing "/". ok is false when
// the root is not btrfs (legacy ext4 SD cards) — the
// same "when applicable" gate as readBattery/readTemperature.
func readBtrfsHealth() (btrfsHealth, bool) {
	var h btrfsHealth

	dev, opts, ok := rootMount()
	if !ok {
		return h, false
	}
	for _, o := range strings.Split(opts, ",") {
		if o == "ro" {
			h.Readonly = true
		}
	}

	fsid, ok := rootFsid(dev)
	if !ok {
		// The root IS btrfs per the mount table; a failed sysfs match must
		// not hide the sensor (readonly detection still works). Devices=0
		// makes the degraded probe visible in the payload.
		return h, true
	}

	devinfo, err := os.ReadDir(filepath.Join(btrfsSysfsRoot, fsid, "devinfo"))
	if err != nil {
		return h, true
	}
	for _, d := range devinfo {
		h.Devices++
		stats, err := os.ReadFile(filepath.Join(btrfsSysfsRoot, fsid, "devinfo", d.Name(), "error_stats"))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(stats), "\n") {
			f := strings.Fields(line)
			if len(f) != 2 {
				continue
			}
			n, err := strconv.Atoi(f[1])
			if err != nil {
				continue
			}
			switch f[0] {
			case "write_errs":
				h.WriteErrs += n
			case "read_errs":
				h.ReadErrs += n
			case "flush_errs":
				h.FlushErrs += n
			case "corruption_errs":
				h.CorruptionErrs += n
			case "generation_errs":
				h.GenerationErrs += n
			}
		}
	}
	return h, true
}

// rootMount returns the source device and mount options of "/" if it is
// btrfs. The last matching line wins — later mounts shadow earlier ones.
func rootMount() (dev, opts string, ok bool) {
	b, err := os.ReadFile(procMountsPath)
	if err != nil {
		return "", "", false
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 || f[1] != "/" {
			continue
		}
		dev, opts, ok = f[0], f[3], f[2] == "btrfs"
	}
	return dev, opts, ok
}

// rootFsid finds the /sys/fs/btrfs/<fsid> directory whose devices/ list
// contains the root's block device, so a user-attached btrfs disk can never
// feed the appliance's health sensor. Non-fsid entries (like the `features`
// directory) are filtered by requiring a devinfo subdir.
func rootFsid(dev string) (string, bool) {
	if resolved, err := filepath.EvalSymlinks(dev); err == nil {
		dev = resolved
	}
	base := filepath.Base(dev)

	entries, err := os.ReadDir(btrfsSysfsRoot)
	if err != nil {
		return "", false
	}
	var candidates []string
	for _, e := range entries {
		if _, err := os.Stat(filepath.Join(btrfsSysfsRoot, e.Name(), "devinfo")); err != nil {
			continue
		}
		candidates = append(candidates, e.Name())
		if _, err := os.Stat(filepath.Join(btrfsSysfsRoot, e.Name(), "devices", base)); err == nil {
			return e.Name(), true
		}
	}
	// Mount-source spellings (mapper names, by-label paths on odd setups) can
	// defeat the basename match; with a single btrfs on the system it can
	// only be the root's.
	if len(candidates) == 1 {
		return candidates[0], true
	}
	return "", false
}
