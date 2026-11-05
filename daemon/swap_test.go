package main

import "testing"

// Captured from the bench Pi 5 (16 KiB pages) under the overnight 2 GB run's
// shape: zram partly full, the swap file on @swap barely touched.
const procSwaps = `Filename				Type		Size		Used		Priority
/dev/zram0                              partition	1018364		255040		100
/swap/swapfile                          file		1048572		16384		10
`

const procVmstat = `nr_free_pages 61234
pswpin 1200
pswpout 16000
oom_kill 2
`

// The two swaps are told apart, so a history shows when zram filled and the
// swap file on flash started taking pages.
func TestSwapSplitsZramFromTheSwapFile(t *testing.T) {
	s := parseSwap(procSwaps, procVmstat, 16384)

	if s.ZramTotalMiB != 994 || s.ZramUsedMiB != 249 {
		t.Errorf("zram = %d/%d MiB, want 249/994", s.ZramUsedMiB, s.ZramTotalMiB)
	}
	if s.FileTotalMiB != 1023 || s.FileUsedMiB != 16 {
		t.Errorf("swap file = %d/%d MiB, want 16/1023", s.FileUsedMiB, s.FileTotalMiB)
	}
}

// vmstat counts pages, and the page size differs between boards (16 KiB on
// the Pi 5 kernel, 4 KiB on x86), so the totals are reported in MiB.
func TestSwapTrafficIsCountedInMiBNotPages(t *testing.T) {
	s := parseSwap(procSwaps, procVmstat, 16384)

	if s.SwappedInMiB != 18 || s.SwappedOutMiB != 250 {
		t.Errorf("swapped in/out = %d/%d MiB, want 18/250", s.SwappedInMiB, s.SwappedOutMiB)
	}
	if s.OOMKills != 2 {
		t.Errorf("oom kills = %d, want 2", s.OOMKills)
	}
}

// A board without a swap file still reports zram, and zeroes for the file.
func TestSwapWithoutASwapFile(t *testing.T) {
	s := parseSwap("Filename Type Size Used Priority\n/dev/zram0 partition 1018364 0 100\n", "", 4096)

	if s.ZramTotalMiB != 994 || s.FileTotalMiB != 0 || s.FileUsedMiB != 0 {
		t.Errorf("got %+v", s)
	}
}
