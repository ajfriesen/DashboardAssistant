package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// ChargeControl sets the battery's charge thresholds from Home Assistant, for
// a device that is plugged in all the time and should not sit at 100 %.
//
// It writes the kernel's standard power_supply attributes, which every laptop
// driver with the feature implements, but each with its own rules:
//
//   - thinkpad_acpi: start 0–99, end 1–100, the start never above the end, and
//     anything else is rejected rather than adjusted. Reads come live from the
//     embedded controller.
//   - dell-laptop: start clamped to 50–95, end to 55–100, at least 5 apart, and
//     the thresholds only apply in the "Custom" charge type.
//   - asus-wmi: an end threshold only, and the driver sets it back to 100 every
//     time it loads, so on every boot.
//
// So there is no table of limits per brand here. The daemon refuses only what
// no driver accepts (a start not below the end), writes in the order that keeps
// the start below the end at every step, and then reports what the hardware
// actually holds. Home Assistant always shows that: a value a driver adjusted,
// a firmware reset, a change in the BIOS. The saved thresholds are applied
// again at boot only (Restore), never fought over between boots.
type ChargeControl struct {
	mu    sync.Mutex
	root  string // /sys/class/power_supply
	write func(path, value string) error
	obs   func()
}

// The sysfs attributes, as named in Documentation/ABI/testing/sysfs-class-power.
const (
	chargeStartAttr = "charge_control_start_threshold"
	chargeEndAttr   = "charge_control_end_threshold"
	chargeTypesAttr = "charge_types"
)

// ChargeState is the battery's slice of the snapshot. A field is nil when the
// battery has no such threshold, which is how the integration knows which
// numbers to create.
type ChargeState struct {
	Start *int `json:"charge_start,omitempty"`
	End   *int `json:"charge_end,omitempty"`
}

// chargePrefs is what Home Assistant last set, as the hardware accepted it.
// Applied again at boot; a field that was never set is never written.
type chargePrefs struct {
	Start *int `json:"start,omitempty"`
	End   *int `json:"end,omitempty"`
}

func NewChargeControl(root string) *ChargeControl {
	return &ChargeControl{
		root:  root,
		write: func(path, v string) error { return os.WriteFile(path, []byte(v), 0) },
	}
}

func (c *ChargeControl) SetObserver(f func()) { c.obs = f }

// battery returns the sysfs directory of the first battery with a charge
// threshold, or "".
func (c *ChargeControl) battery() string {
	supplies, _ := filepath.Glob(filepath.Join(c.root, "*"))
	for _, s := range supplies {
		if !strings.EqualFold(sysStr(s+"/type"), "Battery") {
			continue
		}
		if fileExists(s+"/"+chargeEndAttr) || fileExists(s+"/"+chargeStartAttr) {
			return s
		}
	}
	return ""
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// readThreshold returns the value the hardware holds, or nil when the battery
// has no such attribute or it cannot be read.
func readThreshold(dir, attr string) *int {
	n, err := sysInt(dir + "/" + attr)
	if err != nil {
		return nil
	}
	return &n
}

// State reads the thresholds from the hardware. nil when the device has no
// battery with charge thresholds.
func (c *ChargeControl) State() *ChargeState {
	dir := c.battery()
	if dir == "" {
		return nil
	}
	st := &ChargeState{Start: readThreshold(dir, chargeStartAttr), End: readThreshold(dir, chargeEndAttr)}
	if st.Start == nil && st.End == nil {
		return nil
	}
	return st
}

// Set writes the given thresholds (nil leaves one as it is), saves what the
// hardware accepted for the next boot, and tells Home Assistant.
func (c *ChargeControl) Set(start, end *int) error {
	c.mu.Lock()
	accepted, err := c.apply(start, end)
	if err == nil {
		err = saveChargePrefs(accepted)
	}
	c.mu.Unlock()
	if err == nil && c.obs != nil {
		c.obs()
	}
	return err
}

// apply validates and writes, and returns the prefs to save: the saved ones,
// with the thresholds just written replaced by what the hardware holds now.
func (c *ChargeControl) apply(start, end *int) (chargePrefs, error) {
	p := loadChargePrefs()
	dir := c.battery()
	if dir == "" {
		return p, errors.New("this device's battery has no charge thresholds")
	}
	if start == nil && end == nil {
		return p, errors.New("nothing to set")
	}
	curStart, curEnd := readThreshold(dir, chargeStartAttr), readThreshold(dir, chargeEndAttr)
	if start != nil && curStart == nil {
		return p, errors.New("this device's battery has no start threshold")
	}
	if end != nil && curEnd == nil {
		return p, errors.New("this device's battery has no stop threshold")
	}
	for _, v := range []*int{start, end} {
		if v != nil && (*v < 0 || *v > 100) {
			return p, fmt.Errorf("threshold %d is outside 0–100", *v)
		}
	}
	// The pair as it will be once written, checked as a whole.
	wantStart, wantEnd := curStart, curEnd
	if start != nil {
		wantStart = start
	}
	if end != nil {
		wantEnd = end
	}
	if wantStart != nil && wantEnd != nil && *wantStart >= *wantEnd {
		return p, fmt.Errorf("charging has to start below where it stops (start %d, stop %d)", *wantStart, *wantEnd)
	}

	// Keep the start below the end at every step: lowering the start can never
	// cross the end, raising it can, so then the end goes first.
	type step struct {
		attr string
		v    *int
	}
	steps := []step{{chargeStartAttr, start}, {chargeEndAttr, end}}
	if start != nil && curStart != nil && *start > *curStart {
		steps[0], steps[1] = steps[1], steps[0]
	}
	for _, s := range steps {
		if s.v == nil {
			continue
		}
		if err := c.write(dir+"/"+s.attr, strconv.Itoa(*s.v)); err != nil {
			return p, fmt.Errorf("write %s: %w", s.attr, err)
		}
	}
	c.setChargeType(dir, wantEnd)

	if start != nil {
		p.Start = readThreshold(dir, chargeStartAttr)
	}
	if end != nil {
		p.End = readThreshold(dir, chargeEndAttr)
	}
	return p, nil
}

// setChargeType selects "Custom" on a battery that has it (Dell), where the
// thresholds do nothing in any other charge type, and goes back to "Standard"
// once there is no limit left. Best effort: the thresholds are written either
// way, and a battery without charge types has nothing to switch.
func (c *ChargeControl) setChargeType(dir string, end *int) {
	path := dir + "/" + chargeTypesAttr
	types := strings.Fields(sysStr(path))
	if len(types) == 0 {
		return
	}
	want := "Custom"
	if end == nil || *end >= 100 {
		want = "Standard"
	}
	for _, t := range types {
		if t == "["+want+"]" {
			return // already active
		}
		if t == want {
			if err := c.write(path, want); err != nil {
				log.Printf("charge: could not select the %s charge type: %v", want, err)
			}
			return
		}
	}
}

// Restore applies the saved thresholds at boot. Some drivers forget them on
// every boot (asus-wmi); on the rest it is a no-op. Nothing saved, nothing
// written: the hardware keeps whatever the BIOS or the owner set.
func (c *ChargeControl) Restore() {
	p := loadChargePrefs()
	if p.Start == nil && p.End == nil {
		return
	}
	c.mu.Lock()
	_, err := c.apply(p.Start, p.End)
	c.mu.Unlock()
	if err != nil {
		log.Printf("charge: could not apply the saved thresholds: %v", err)
	}
}

// Reset puts the battery back to charging fully and forgets the saved
// thresholds. Called by factory reset: a ThinkPad's controller would otherwise
// keep the limit, with nothing left on the device to change it.
func (c *ChargeControl) Reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if dir := c.battery(); dir != "" {
		var start, end *int
		if readThreshold(dir, chargeStartAttr) != nil {
			start = ptr(0)
		}
		if readThreshold(dir, chargeEndAttr) != nil {
			end = ptr(100)
		}
		if _, err := c.apply(start, end); err != nil {
			log.Printf("charge: could not restore full charging: %v", err)
		}
	}
	if err := os.Remove(chargeFile); err != nil && !os.IsNotExist(err) {
		log.Printf("charge: %v", err)
	}
}

func loadChargePrefs() chargePrefs {
	var p chargePrefs
	if b, err := os.ReadFile(chargeFile); err == nil {
		_ = json.Unmarshal(b, &p)
	}
	return p
}

func saveChargePrefs(p chargePrefs) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return writeAtomic(chargeFile, b, 0o644)
}

func ptr(n int) *int { return &n }
