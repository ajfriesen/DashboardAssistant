package main

import (
	"os"
	"path/filepath"
	"testing"
)

// fakeBtrfs points the probe at a fake mounts file and sysfs tree, restoring
// the real paths afterwards (the stateDir swap pattern from update_test.go).
func fakeBtrfs(t *testing.T, mounts string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "mounts"), []byte(mounts), 0o644); err != nil {
		t.Fatal(err)
	}
	sysfs := filepath.Join(dir, "sysfs")
	if err := os.Mkdir(sysfs, 0o755); err != nil {
		t.Fatal(err)
	}
	origSysfs, origMounts := btrfsSysfsRoot, procMountsPath
	btrfsSysfsRoot, procMountsPath = sysfs, filepath.Join(dir, "mounts")
	t.Cleanup(func() { btrfsSysfsRoot, procMountsPath = origSysfs, origMounts })
	return sysfs
}

// addFsid creates /sys/fs/btrfs/<fsid> holding the named device and one
// devinfo entry per errorStats string (empty string = no error_stats file).
func addFsid(t *testing.T, sysfs, fsid, device string, errorStats ...string) {
	t.Helper()
	for _, sub := range []string{"devices", "devinfo"} {
		if err := os.MkdirAll(filepath.Join(sysfs, fsid, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(sysfs, fsid, "devices", device), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for i, stats := range errorStats {
		devdir := filepath.Join(sysfs, fsid, "devinfo", string(rune('1'+i)))
		if err := os.Mkdir(devdir, 0o755); err != nil {
			t.Fatal(err)
		}
		if stats == "" {
			continue
		}
		if err := os.WriteFile(filepath.Join(devdir, "error_stats"), []byte(stats), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

const cleanStats = "write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 0\ngeneration_errs 0\n"

func TestBtrfsHealthClean(t *testing.T) {
	sysfs := fakeBtrfs(t, "/dev/sda2 / btrfs rw,noatime,compress=zstd:3 0 0\n")
	addFsid(t, sysfs, "abcd-1234", "sda2", cleanStats)

	h, ok := readBtrfsHealth()
	if !ok {
		t.Fatal("btrfs root not detected")
	}
	if h.Readonly || h.Devices != 1 ||
		h.WriteErrs+h.ReadErrs+h.FlushErrs+h.CorruptionErrs+h.GenerationErrs != 0 {
		t.Fatalf("unexpected health: %+v", h)
	}
}

func TestBtrfsHealthCountersSummedAcrossDevices(t *testing.T) {
	sysfs := fakeBtrfs(t, "/dev/sda2 / btrfs rw 0 0\n")
	addFsid(t, sysfs, "abcd-1234", "sda2",
		"write_errs 1\nread_errs 0\nflush_errs 0\ncorruption_errs 2\ngeneration_errs 0\n",
		"write_errs 0\nread_errs 4\nflush_errs 0\ncorruption_errs 3\ngeneration_errs 0\n")

	h, ok := readBtrfsHealth()
	if !ok {
		t.Fatal("btrfs root not detected")
	}
	if h.Devices != 2 || h.WriteErrs != 1 || h.ReadErrs != 4 || h.CorruptionErrs != 5 {
		t.Fatalf("unexpected sums: %+v", h)
	}
}

func TestBtrfsHealthReadonly(t *testing.T) {
	sysfs := fakeBtrfs(t, "/dev/sda2 / btrfs ro,noatime 0 0\n")
	addFsid(t, sysfs, "abcd-1234", "sda2", cleanStats)

	h, ok := readBtrfsHealth()
	if !ok || !h.Readonly {
		t.Fatalf("ro root not flagged: ok=%v %+v", ok, h)
	}
}

func TestBtrfsHealthAbsentOnExt4(t *testing.T) {
	fakeBtrfs(t, "/dev/mmcblk0p2 / ext4 rw,noatime 0 0\n")
	if _, ok := readBtrfsHealth(); ok {
		t.Fatal("ext4 root reported as btrfs")
	}
}

func TestBtrfsHealthAbsentWithoutRootMount(t *testing.T) {
	fakeBtrfs(t, "tmpfs /run tmpfs rw 0 0\n")
	if _, ok := readBtrfsHealth(); ok {
		t.Fatal("missing / mount reported as btrfs")
	}
}

func TestBtrfsHealthMissingErrorStats(t *testing.T) {
	sysfs := fakeBtrfs(t, "/dev/sda2 / btrfs rw 0 0\n")
	addFsid(t, sysfs, "abcd-1234", "sda2", "")

	h, ok := readBtrfsHealth()
	if !ok || h.Devices != 1 || h.CorruptionErrs != 0 {
		t.Fatalf("device without error_stats mishandled: ok=%v %+v", ok, h)
	}
}

func TestBtrfsHealthPicksRootFsid(t *testing.T) {
	sysfs := fakeBtrfs(t, "/dev/sda2 / btrfs rw 0 0\n")
	// A stray non-fsid entry like the real tree's `features` dir.
	if err := os.Mkdir(filepath.Join(sysfs, "features"), 0o755); err != nil {
		t.Fatal(err)
	}
	addFsid(t, sysfs, "other-usb-stick", "sdb1",
		"write_errs 9\nread_errs 9\nflush_errs 9\ncorruption_errs 9\ngeneration_errs 9\n")
	addFsid(t, sysfs, "root-fsid", "sda2", cleanStats)

	h, ok := readBtrfsHealth()
	if !ok || h.CorruptionErrs != 0 || h.Devices != 1 {
		t.Fatalf("wrong filesystem consulted: ok=%v %+v", ok, h)
	}
}

func TestBtrfsHealthNoSysfsMatchStaysPresent(t *testing.T) {
	fakeBtrfs(t, "/dev/sda2 / btrfs ro 0 0\n")

	h, ok := readBtrfsHealth()
	if !ok || h.Devices != 0 || !h.Readonly {
		t.Fatalf("sysfs-less btrfs root mishandled: ok=%v %+v", ok, h)
	}
}

func TestBtrfsHealthSubvolumeMountsShareOneFs(t *testing.T) {
	// x86 disk layout: / and /nix are subvolumes of the same filesystem;
	// only the / line is consulted, so nothing is double-counted.
	sysfs := fakeBtrfs(t,
		"/dev/vda2 / btrfs rw,compress=zstd,subvol=/@ 0 0\n"+
			"/dev/vda2 /nix btrfs rw,compress=zstd,subvol=/@nix 0 0\n")
	addFsid(t, sysfs, "abcd-1234", "vda2",
		"write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 1\ngeneration_errs 0\n")

	h, ok := readBtrfsHealth()
	if !ok || h.Devices != 1 || h.CorruptionErrs != 1 {
		t.Fatalf("subvolume layout mishandled: ok=%v %+v", ok, h)
	}
}
