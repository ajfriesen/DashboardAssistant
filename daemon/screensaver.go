package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Screen savers are self-contained HTML pages embedded under web/screensavers/;
// the file name (minus .html) is the name HA shows in its dropdown. Adding one is
// dropping a file there — nothing else needs registering.
const (
	screensaverDir     = "web/screensavers"
	screensaverDefault = "clock"
	// Idle minutes before the saver starts on a device that never set its own.
	screensaverDefaultTimeout = 10
	// Idle timeout ceiling in minutes, mirrored by the HA number entity. 0 = never.
	screensaverMaxTimeout = 240
)

// Screensaver shows a full-screen saver over the kiosk after an idle timeout, or
// on demand from HA. Like Zoom it can't reach the browser itself, so it writes
// "start <name>" / "stop" to a FIFO and an agent in the Sway session overlays the
// saver on the live page over CDP (see kiosk.nix). An overlay rather than a
// navigation, so waking the screen doesn't reload the dashboard.
//
// The chosen saver and timeout are persisted; whether one is showing is not — a
// session restart drops the overlay, and the agent reports "saver off" on start.
type Screensaver struct {
	mu       sync.Mutex
	active   bool
	name     string
	timeout  int       // minutes; 0 disables the idle trigger
	armed    time.Time // idle baseline, reset on stop so a manual stop isn't undone by the next idle tick
	fifo     string
	observer func()
}

type screensaverPrefs struct {
	Name    string `json:"name"`
	Timeout int    `json:"timeout"`
}

// NewScreensaver loads the persisted prefs. The FIFO path can be overridden for
// testing off-device.
func NewScreensaver() *Screensaver {
	fifo := screensaverFifo
	if v := os.Getenv("DASHBOARD_ASSISTANT_SCREENSAVER_FIFO"); v != "" {
		fifo = v
	}
	p := loadScreensaverPrefs()
	return &Screensaver{name: p.Name, timeout: p.Timeout, armed: time.Now(), fifo: fifo}
}

// SetObserver registers a callback fired (outside the lock) after any change.
func (s *Screensaver) SetObserver(f func()) {
	s.mu.Lock()
	s.observer = f
	s.mu.Unlock()
}

// Options lists the embedded screen savers, sorted.
func (s *Screensaver) Options() []string { return screensaverNames() }

func (s *Screensaver) Active() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

func (s *Screensaver) Name() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.name
}

func (s *Screensaver) Timeout() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.timeout
}

// Start shows the selected screen saver. Restarting one that is already showing
// is allowed — it is how a changed selection takes effect immediately.
func (s *Screensaver) Start() error {
	s.mu.Lock()
	if err := s.writeCmd("start " + s.name); err != nil {
		s.mu.Unlock()
		return err
	}
	s.active = true
	obs := s.observer
	s.mu.Unlock()
	if obs != nil {
		obs()
	}
	return nil
}

// Stop hides the screen saver. A no-op when none is showing, so it is safe to
// call on every touch.
func (s *Screensaver) Stop() error {
	s.mu.Lock()
	if !s.active {
		s.mu.Unlock()
		return nil
	}
	if err := s.writeCmd("stop"); err != nil {
		s.mu.Unlock()
		return err
	}
	s.active = false
	s.armed = time.Now()
	obs := s.observer
	s.mu.Unlock()
	if obs != nil {
		obs()
	}
	return nil
}

// Reset tells the in-session agent to drop any saver left over from before a
// daemon restart. Best-effort: no session yet just means nothing to drop.
func (s *Screensaver) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.writeCmd("stop")
}

// ReportOff records that the overlay is gone without driving the FIFO — the
// session restarted and took it with it.
func (s *Screensaver) ReportOff() {
	s.mu.Lock()
	changed := s.active
	s.active = false
	s.armed = time.Now()
	obs := s.observer
	s.mu.Unlock()
	if changed && obs != nil {
		obs()
	}
}

// SetName picks which screen saver to show, and swaps it in if one is up.
func (s *Screensaver) SetName(name string) error {
	if !slices.Contains(screensaverNames(), name) {
		return fmt.Errorf("unknown screen saver %q; want one of %v", name, screensaverNames())
	}
	s.mu.Lock()
	s.name = name
	active := s.active
	obs := s.observer
	s.save()
	s.mu.Unlock()
	if active {
		return s.Start()
	}
	if obs != nil {
		obs()
	}
	return nil
}

// SetTimeout sets the idle timeout in minutes (0 = never), clamped to range.
func (s *Screensaver) SetTimeout(minutes int) {
	minutes = max(0, min(minutes, screensaverMaxTimeout))
	s.mu.Lock()
	s.timeout = minutes
	s.armed = time.Now()
	obs := s.observer
	s.save()
	s.mu.Unlock()
	if obs != nil {
		obs()
	}
}

// Tick starts the screen saver once the kiosk has been idle for the timeout.
// idle is the seconds since the last touch; eligible is false when there is no
// point (the panel is off, or the device isn't showing a dashboard yet).
func (s *Screensaver) Tick(idle int, eligible bool) {
	s.mu.Lock()
	since := int(time.Since(s.armed).Seconds())
	due := eligible && !s.active && s.timeout > 0 && min(idle, since) >= s.timeout*60
	s.mu.Unlock()
	if due {
		if err := s.Start(); err != nil {
			fmt.Fprintf(os.Stderr, "screensaver: %v\n", err)
		}
	}
}

// save persists the prefs; caller holds the lock. Best-effort, like saveZoom.
func (s *Screensaver) save() {
	b, _ := json.Marshal(screensaverPrefs{Name: s.name, Timeout: s.timeout})
	tmp := screensaverFile + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o664); err != nil {
		fmt.Fprintf(os.Stderr, "screensaver: save %s: %v\n", screensaverFile, err)
		return
	}
	if err := os.Rename(tmp, screensaverFile); err != nil {
		fmt.Fprintf(os.Stderr, "screensaver: save %s: %v\n", screensaverFile, err)
	}
}

// writeCmd sends one command line to the in-session agent over the FIFO.
// O_NONBLOCK so opening a reader-less FIFO fails with ENXIO instead of blocking.
func (s *Screensaver) writeCmd(line string) error {
	f, err := os.OpenFile(s.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("screensaver session not ready: %w", err)
	}
	_, werr := f.WriteString(line + "\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write screensaver fifo: %w", werr)
	}
	return nil
}

// loadScreensaverPrefs reads the persisted prefs, falling back to the default
// saver and timeout on a missing or bad file, or a saver that no longer exists
// in this build. A stored timeout of 0 is kept: that is the user turning it off.
func loadScreensaverPrefs() screensaverPrefs {
	p := screensaverPrefs{Name: screensaverDefault, Timeout: screensaverDefaultTimeout}
	if b, err := os.ReadFile(screensaverFile); err == nil {
		_ = json.Unmarshal(b, &p)
	}
	if !slices.Contains(screensaverNames(), p.Name) {
		p.Name = screensaverDefault
	}
	p.Timeout = max(0, min(p.Timeout, screensaverMaxTimeout))
	return p
}

func screensaverNames() []string {
	entries, _ := fs.ReadDir(webFS, screensaverDir)
	var out []string
	for _, e := range entries {
		if n, ok := strings.CutSuffix(e.Name(), ".html"); ok {
			out = append(out, n)
		}
	}
	return out
}

// handleScreensaverPage serves /screensaver/<name>: the saver's HTML, fetched by
// the in-session agent (and handy for previewing one in a browser).
func (s *server) handleScreensaverPage(w http.ResponseWriter, r *http.Request) {
	name := path.Base(r.URL.Path)
	if !slices.Contains(screensaverNames(), name) {
		http.NotFound(w, r)
		return
	}
	serveEmbedded(w, screensaverDir+"/"+name+".html")
}
