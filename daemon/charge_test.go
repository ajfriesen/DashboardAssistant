package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// fakeBattery is a battery under a temporary /sys/class/power_supply. Its
// write hook stands in for the kernel driver, so each test can apply the rules
// of the driver it is about (see the kernel sources named below).
type fakeBattery struct {
	t      *testing.T
	dir    string
	writes []string // "<attr>=<value>", in order
}

func newFakeBattery(t *testing.T, attrs map[string]string) (*ChargeControl, *fakeBattery) {
	t.Helper()
	tempState(t)
	root := t.TempDir()
	// An AC adapter first, which must be skipped.
	ac := filepath.Join(root, "AC")
	must(t, os.MkdirAll(ac, 0o755))
	must(t, os.WriteFile(filepath.Join(ac, "type"), []byte("Mains\n"), 0o644))
	b := &fakeBattery{t: t, dir: filepath.Join(root, "BAT0")}
	must(t, os.MkdirAll(b.dir, 0o755))
	b.set("type", "Battery")
	b.set("capacity", "77")
	for k, v := range attrs {
		b.set(k, v)
	}
	c := NewChargeControl(root)
	return c, b
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (b *fakeBattery) set(attr, v string) {
	must(b.t, os.WriteFile(filepath.Join(b.dir, attr), []byte(v+"\n"), 0o644))
}

func (b *fakeBattery) get(attr string) string { return sysStr(filepath.Join(b.dir, attr)) }

func (b *fakeBattery) num(attr string) int {
	n, err := strconv.Atoi(b.get(attr))
	must(b.t, err)
	return n
}

var errRejected = errors.New("invalid argument")

// thinkpad follows thinkpad_acpi: start 0–99, end 1–100, start never above end,
// and anything else is rejected rather than adjusted.
func (b *fakeBattery) thinkpad(c *ChargeControl) {
	c.write = func(path, v string) error {
		attr := filepath.Base(path)
		n, _ := strconv.Atoi(v)
		b.writes = append(b.writes, attr+"="+v)
		switch attr {
		case chargeStartAttr:
			if n > 99 || n > b.num(chargeEndAttr) {
				return errRejected
			}
		case chargeEndAttr:
			if n < 1 || n > 100 || n < b.num(chargeStartAttr) {
				return errRejected
			}
		}
		b.set(attr, v)
		return nil
	}
}

// dell follows dell-laptop: start is clamped to 50–95, end to 55–100, and the
// pair is pushed at least 5 apart. Nothing is rejected.
func (b *fakeBattery) dell(c *ChargeControl) {
	c.write = func(path, v string) error {
		attr := filepath.Base(path)
		b.writes = append(b.writes, attr+"="+v)
		if attr == chargeTypesAttr {
			b.set(attr, dellTypes(v))
			return nil
		}
		n, _ := strconv.Atoi(v)
		switch attr {
		case chargeStartAttr:
			n = max(50, min(n, 95))
			if end := b.num(chargeEndAttr); end-n < 5 {
				n = end - 5
			}
		case chargeEndAttr:
			n = max(55, min(n, 100))
			if start := b.num(chargeStartAttr); n-start < 5 {
				n = start + 5
			}
		}
		b.set(attr, strconv.Itoa(n))
		return nil
	}
}

func dellTypes(active string) string {
	out := ""
	for _, t := range []string{"Trickle", "Fast", "Standard", "Adaptive", "Custom"} {
		if t == active {
			t = "[" + t + "]"
		}
		if out != "" {
			out += " "
		}
		out += t
	}
	return out
}

func TestChargeUnsupportedWithoutThresholds(t *testing.T) {
	c, _ := newFakeBattery(t, nil)
	if st := c.State(); st != nil {
		t.Fatalf("State = %+v, want nil on a battery without thresholds", st)
	}
	if err := c.Set(nil, ptr(80)); err == nil {
		t.Fatal("Set must fail on a battery without thresholds")
	}
}

func TestChargeStateReadsTheHardware(t *testing.T) {
	c, _ := newFakeBattery(t, map[string]string{chargeStartAttr: "40", chargeEndAttr: "80"})
	st := c.State()
	if st == nil || st.Start == nil || *st.Start != 40 || st.End == nil || *st.End != 80 {
		t.Fatalf("State = %+v, want start 40, end 80", st)
	}
}

// asus-wmi has an end threshold only.
func TestChargeEndOnly(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeEndAttr: "100"})
	st := c.State()
	if st == nil || st.Start != nil || st.End == nil || *st.End != 100 {
		t.Fatalf("State = %+v, want end only", st)
	}
	if err := c.Set(ptr(40), nil); err == nil {
		t.Fatal("setting a start threshold the battery lacks must fail")
	}
	must(t, c.Set(nil, ptr(60)))
	if got := b.get(chargeEndAttr); got != "60" {
		t.Fatalf("end = %s, want 60", got)
	}
}

// ThinkPad rejects a start above the end, so lowering both writes the start
// first and raising both writes the end first.
func TestChargeWritesInAnOrderThinkPadAccepts(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "75", chargeEndAttr: "80"})
	b.thinkpad(c)

	must(t, c.Set(ptr(30), ptr(40)))
	if b.get(chargeStartAttr) != "30" || b.get(chargeEndAttr) != "40" {
		t.Fatalf("after lowering: %s/%s, want 30/40", b.get(chargeStartAttr), b.get(chargeEndAttr))
	}

	must(t, c.Set(ptr(70), ptr(90)))
	if b.get(chargeStartAttr) != "70" || b.get(chargeEndAttr) != "90" {
		t.Fatalf("after raising: %s/%s, want 70/90", b.get(chargeStartAttr), b.get(chargeEndAttr))
	}
}

func TestChargeRefusesAStartNotBelowTheEnd(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "40", chargeEndAttr: "80"})
	b.thinkpad(c)

	for _, tc := range []struct {
		name       string
		start, end *int
	}{
		{"both", ptr(60), ptr(50)},
		{"equal", ptr(50), ptr(50)},
		{"start above the current end", ptr(85), nil},
		{"end below the current start", nil, ptr(30)},
		{"out of range", nil, ptr(101)},
		{"negative", ptr(-1), nil},
		{"nothing", nil, nil},
	} {
		if err := c.Set(tc.start, tc.end); err == nil {
			t.Errorf("%s: Set succeeded, want an error", tc.name)
		}
	}
	if len(b.writes) != 0 {
		t.Fatalf("refused requests wrote %v", b.writes)
	}
}

// Dell clamps instead of rejecting; what Home Assistant sees, and what is saved
// for the next boot, is what the hardware accepted.
func TestChargeReportsWhatTheHardwareAccepted(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{
		chargeStartAttr: "50", chargeEndAttr: "100", chargeTypesAttr: dellTypes("Standard"),
	})
	b.dell(c)

	must(t, c.Set(ptr(20), ptr(40)))

	st := c.State()
	if *st.Start != 50 || *st.End != 55 {
		t.Fatalf("State = %d/%d, want what Dell accepted, 50/55", *st.Start, *st.End)
	}
	p := loadChargePrefs()
	if p.Start == nil || *p.Start != 50 || p.End == nil || *p.End != 55 {
		t.Fatalf("saved %+v, want 50/55", p)
	}
}

// On Dell the thresholds only apply in the Custom charge type.
func TestChargeSwitchesDellToCustomAndBack(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{
		chargeStartAttr: "50", chargeEndAttr: "100", chargeTypesAttr: dellTypes("Standard"),
	})
	b.dell(c)

	must(t, c.Set(nil, ptr(80)))
	if got := b.get(chargeTypesAttr); got != dellTypes("Custom") {
		t.Fatalf("charge_types = %q, want Custom active", got)
	}

	must(t, c.Set(nil, ptr(100)))
	if got := b.get(chargeTypesAttr); got != dellTypes("Standard") {
		t.Fatalf("charge_types = %q, want Standard back with no limit", got)
	}
}

// asus-wmi sets the end back to 100 every time it loads, so the saved
// thresholds are applied again at boot.
func TestChargeRestoreAppliesTheSavedThresholds(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeEndAttr: "100"})
	must(t, c.Set(nil, ptr(60)))

	b.set(chargeEndAttr, "100") // reboot
	c = NewChargeControl(filepath.Dir(b.dir))
	c.Restore()

	if got := b.get(chargeEndAttr); got != "60" {
		t.Fatalf("end after Restore = %s, want 60", got)
	}
}

func TestChargeRestoreLeavesTheHardwareAloneWhenNothingWasSet(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "40", chargeEndAttr: "80"})
	b.thinkpad(c)

	c.Restore()

	if len(b.writes) != 0 {
		t.Fatalf("Restore wrote %v with nothing saved", b.writes)
	}
}

// A firmware reset or a change in the BIOS mid-session shows in Home Assistant
// rather than being written over.
func TestChargeFollowsTheHardwareBetweenBoots(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "0", chargeEndAttr: "100"})
	b.thinkpad(c)
	must(t, c.Set(ptr(40), ptr(80)))
	b.writes = nil
	var notified int
	c.SetObserver(func() { notified++ })

	b.set(chargeStartAttr, "0")
	b.set(chargeEndAttr, "100")

	st := c.State()
	if *st.Start != 0 || *st.End != 100 {
		t.Fatalf("State = %d/%d, want the hardware's 0/100", *st.Start, *st.End)
	}
	if len(b.writes) != 0 {
		t.Fatalf("State wrote %v", b.writes)
	}
}

// A factory reset puts the battery back to charging fully: the controller on a
// ThinkPad would otherwise keep the limit with nothing left to change it.
func TestChargeResetRestoresFullCharging(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "0", chargeEndAttr: "100"})
	b.thinkpad(c)
	must(t, c.Set(ptr(40), ptr(50)))

	c.Reset()

	if b.get(chargeStartAttr) != "0" || b.get(chargeEndAttr) != "100" {
		t.Fatalf("after Reset: %s/%s, want 0/100", b.get(chargeStartAttr), b.get(chargeEndAttr))
	}
	if _, err := os.Stat(chargeFile); !os.IsNotExist(err) {
		t.Fatalf("saved thresholds still on disk after Reset: %v", err)
	}
}

func TestChargeSetNotifiesTheObserver(t *testing.T) {
	c, _ := newFakeBattery(t, map[string]string{chargeEndAttr: "100"})
	var notified int
	c.SetObserver(func() { notified++ })
	must(t, c.Set(nil, ptr(80)))
	if notified != 1 {
		t.Fatalf("observer called %d times, want 1", notified)
	}
}

func batteryRequest(h *HAHub, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/ha/battery", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	h.routes().ServeHTTP(rec, req)
	return rec
}

func TestBatteryEndpointIsAbsentWithoutThresholds(t *testing.T) {
	c, _ := newFakeBattery(t, nil)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}
	h.SetCharge(c)
	if rec := batteryRequest(h, `{"charge_end": 80}`); rec.Code != http.StatusNotFound {
		t.Fatalf("POST /api/ha/battery = %d, want 404", rec.Code)
	}
}

func TestBatteryEndpointRefusesAnImpossiblePair(t *testing.T) {
	c, b := newFakeBattery(t, map[string]string{chargeStartAttr: "40", chargeEndAttr: "80"})
	h := &HAHub{token: "tok", pair: NewPairing("tok")}
	h.SetCharge(c)
	rec := batteryRequest(h, `{"charge_start": 90}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "below") {
		t.Fatalf("POST /api/ha/battery = %d %s, want 400 explaining the order", rec.Code, rec.Body)
	}
	if b.get(chargeStartAttr) != "40" {
		t.Fatalf("start = %s, want it untouched", b.get(chargeStartAttr))
	}
}

// The snapshot names the fields the integration keys its numbers on, and
// leaves out a threshold the battery does not have.
func TestBatterySnapshotCarriesTheThresholds(t *testing.T) {
	var s stateSnapshot
	s.Battery.Present = true
	s.Battery.ChargeState = &ChargeState{End: ptr(80)}
	b, err := json.Marshal(s.Battery)
	must(t, err)
	if got := string(b); !strings.Contains(got, `"charge_end":80`) || strings.Contains(got, "charge_start") {
		t.Fatalf("battery = %s, want charge_end only", got)
	}
}
