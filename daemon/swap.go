package main

import (
	"os"
	"strconv"
	"strings"
)

// Swap is how much of each kind of swap is in use, and how much has moved
// through it since boot. zram (compressed RAM) and the swap file on @swap are
// reported apart: zram fills first (it has the higher priority, see
// modules/core/memory.nix), so the swap file's use is the measure of how often
// a board ran out of compressed RAM and wrote to flash.
type Swap struct {
	ZramTotalMiB  int `json:"zram_total_mib"`
	ZramUsedMiB   int `json:"zram_used_mib"`
	FileTotalMiB  int `json:"file_total_mib"`
	FileUsedMiB   int `json:"file_used_mib"`
	SwappedInMiB  int `json:"swapped_in_mib"`  // since boot
	SwappedOutMiB int `json:"swapped_out_mib"` // since boot
	OOMKills      int `json:"oom_kills"`       // kernel OOM kills since boot
}

func readSwap() Swap {
	swaps, _ := os.ReadFile("/proc/swaps")
	vmstat, _ := os.ReadFile("/proc/vmstat")
	return parseSwap(string(swaps), string(vmstat), os.Getpagesize())
}

// parseSwap reads /proc/swaps (sizes in KiB) and /proc/vmstat (swap traffic in
// pages, which are 16 KiB on the Pi 5 kernel and 4 KiB on x86).
func parseSwap(swaps, vmstat string, pageSize int) Swap {
	var s Swap
	for _, line := range strings.Split(swaps, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 || f[0] == "Filename" {
			continue
		}
		size, err1 := strconv.Atoi(f[2])
		used, err2 := strconv.Atoi(f[3])
		if err1 != nil || err2 != nil {
			continue
		}
		if strings.HasPrefix(f[0], "/dev/zram") {
			s.ZramTotalMiB += size / 1024
			s.ZramUsedMiB += used / 1024
		} else {
			s.FileTotalMiB += size / 1024
			s.FileUsedMiB += used / 1024
		}
	}
	pagesToMiB := func(pages int) int { return int(int64(pages) * int64(pageSize) / (1 << 20)) }
	for _, line := range strings.Split(vmstat, "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		n, err := strconv.Atoi(f[1])
		if err != nil {
			continue
		}
		switch f[0] {
		case "pswpin":
			s.SwappedInMiB = pagesToMiB(n)
		case "pswpout":
			s.SwappedOutMiB = pagesToMiB(n)
		case "oom_kill":
			s.OOMKills = n
		}
	}
	return s
}
