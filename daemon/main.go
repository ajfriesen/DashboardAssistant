// Command dashboard-assistant-api is the management daemon for Dashboard Assistant OS.
//
// It owns first-boot provisioning: it computes the device state (SETUP /
// RECONNECT / READY) that the Cage/Chromium launcher polls, serves the on-screen
// splash/sponsor pages, and drives NetworkManager over D-Bus to join Wi-Fi.
//
// Nothing on the device screen reconfigures the device: the kiosk is a wall panel
// that guests touch. Recovery (rollback, factory reset) lives on a separate LAN
// listener instead — see admin.go.
package main

import (
	"bufio"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

//go:embed web
var webFS embed.FS

// State is what the kiosk launcher polls to decide which URL to display.
type State string

const (
	StateSetup      State = "SETUP"      // fresh device — show the seed/awaiting-config splash
	StateConnecting State = "CONNECTING" // provisioned but never yet online — first-time connect
	StateReconnect  State = "RECONNECT"  // provisioned, was online, link dropped — reconnecting
	StateReady      State = "READY"      // provisioned and online — show HA
)

type server struct {
	nm    *NetworkManager // nil if no Wi-Fi device / D-Bus unavailable
	ha    *HAHub          // owns the HA API state + SSE subscribers
	pages *Pages          // the pushable page list + current index
}

// deriveState implements the first-boot decision flow.
func (s *server) deriveState() State {
	// Network first: a device that isn't on the network yet can't be shown a
	// dashboard or added to Home Assistant, so offline always shows connect/
	// reconnect — distinguished so a fresh device says "connecting", not the
	// misleading "reconnecting".
	if s.nm == nil || !s.nm.Connected() {
		if WasOnline() {
			return StateReconnect
		}
		return StateConnecting
	}
	// Online but not yet added → the guided "add me in Home Assistant" screen
	// (pairing pushes the login token, and optionally a URL). Once added the
	// device is READY: the kiosk shows the configured dashboard URL, or the
	// built-in default (http://homeassistant:8123/) when none was pushed — a
	// present default never keeps a set-up device stuck on the add screen.
	if !Provisioned() {
		return StateSetup
	}
	return StateReady
}

func main() {
	addr := os.Getenv("DASHBOARD_ASSISTANT_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	if err := ensureStateDir(); err != nil {
		log.Printf("warning: state dir: %v", err)
	}

	nm, err := NewNetworkManager()
	if err != nil {
		// Provisioning is degraded but the daemon still serves state/health.
		log.Printf("warning: NetworkManager unavailable: %v", err)
	}
	disp := NewDisplay()
	pages := NewPages()
	act := NewActivity()
	upd := NewUpdateChecker()
	zoom := NewZoom()
	theme := NewTheme()
	rot := NewRotation()
	snd := NewSendspin()
	hub := NewHAHub(loadAPIToken(), disp, pages, act, upd, zoom, theme, rot, snd)
	srv := &server{nm: nm, ha: hub, pages: pages}

	// The Sendspin player's unit has no install target — this daemon owns its
	// on/off state — so the persisted choice has to be applied on every boot.
	// In a goroutine because it talks to systemd over D-Bus and must not delay
	// the listeners below.
	go snd.Reconcile()

	// Home Assistant API: an authenticated LAN listener the first-party HACS
	// integration polls and subscribes to (SSE). Runs on its own port, separate
	// from the loopback :8080 admin surface below.
	go serveHAAPI(hub)

	// Reverse channel: the in-session agents report the real display power state
	// and touch activity here, keeping HA in sync with changes that never went
	// through an API command (the hub observers broadcast them over SSE).
	go watchDisplayState(disp, act)

	// Move the kiosk off the "Reconnecting…" splash once the device becomes READY.
	// The launcher only reads state once at session start, so a box that booted
	// offline would otherwise sit on the splash forever after the network returns.
	go watchReadyTransition(srv)

	// Poll the release source for the latest version; the checker fires the hub's
	// observer to push the update state whenever it changes.
	go upd.Run()

	// Refresh the periodic sensors on a ticker: the touch counter (so it climbs
	// while idle; touches reset it to 0 immediately via the observer), memory,
	// disk and host diagnostics — broadcast to SSE subscribers.
	go func() {
		for range time.Tick(10 * time.Second) {
			hub.broadcast()
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeText(w, http.StatusOK, "ok")
	})
	mux.HandleFunc("/api/state", srv.handleState)

	// Waiting splash — loopback only (the kiosk browser is local). Provisioning is
	// seed-only (see /api/import), and there is deliberately no on-screen panel
	// that can re-point or recover the kiosk; that lives on the admin listener.
	mux.Handle("/waiting", loopbackOnly(http.HandlerFunc(srv.handleWaitingPage)))
	// Sponsor splash — reached from the ❤ button on the kiosk bar. Static page
	// (importance of sponsoring + a QR to GitHub Sponsors); loopback only like the
	// rest of the on-device UI.
	mux.Handle("/sponsor", loopbackOnly(http.HandlerFunc(srv.handleSponsorPage)))
	// Import a YAML config bundle (HA URL / token / Wi-Fi / API token / pages), fed
	// by the USB and ESP importers. Loopback only. This is the sole config path.
	mux.Handle("/api/import", loopbackOnly(http.HandlerFunc(srv.handleImport)))
	// Page navigation (waybar Prev/Next buttons). The page list itself is managed
	// through the HA integration (the "Page N" text slots), not the web UI.
	mux.Handle("/api/nav", loopbackOnly(http.HandlerFunc(srv.handleNav)))
	// Read-only device info, shown behind the sponsor page's info button and
	// re-served verbatim on the admin listener. Carries no secret.
	mux.Handle("/api/info", loopbackOnly(http.HandlerFunc(srv.handleInfo)))

	// Recovery over the LAN: the screen has no way to roll back or reset, so this
	// is the only one. Unauthenticated by design — see admin.go.
	go serveAdmin(srv)

	mux.HandleFunc("/", srv.handleRoot)

	log.Printf("dashboard-assistant-api listening on %s (state=%s)", addr, srv.deriveState())
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	// Point a human who hits the daemon directly at the waiting splash. Fresh
	// devices are provisioned from a seed file, not an on-screen wizard, so there
	// is nothing interactive to send them to. Recovery is on the admin listener.
	http.Redirect(w, r, "/waiting", http.StatusFound)
}

func (s *server) handleState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"state": string(s.deriveState())})
}

func (s *server) handleWaitingPage(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "web/waiting.html")
}

func (s *server) handleSponsorPage(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "web/sponsor.html")
}

func (s *server) handleImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1 MiB cap
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body"})
		return
	}
	applied, err := s.applyImport(data)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	log.Printf("import applied: %v", applied)
	writeJSON(w, http.StatusOK, map[string]any{"applied": applied})

	// Relaunch the kiosk so it re-reads state (new URL / provisioned).
	if len(applied) > 0 {
		go func() {
			if err := restartKiosk(); err != nil {
				log.Printf("restart kiosk: %v", err)
			}
		}()
	}
}

// handleNav cycles or jumps the displayed page. Body: {"dir":"next"|"prev"} for
// the waybar buttons, or {"page":"<label>"} to jump. POST only.
func (s *server) handleNav(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	var req struct {
		Dir  string `json:"dir"`
		Page string `json:"page"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	switch {
	case req.Page != "":
		s.pages.Select(req.Page)
	case req.Dir == "next":
		s.pages.Next()
	case req.Dir == "prev":
		s.pages.Prev()
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "dir must be next/prev, or give a page"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"page": s.pages.CurrentLabel()})
}

// handleInfo returns read-only device identity + network details. The node id /
// machine id are surfaced here (rather than in the device name) so they're
// discoverable without cluttering the label.
//
// It deliberately carries no secret. It used to return the device API token for
// the old on-screen Config panel, which meant anyone who walked up to the tablet
// could read the bearer token for the :8081 API — factory reset, OS downgrade,
// arbitrary dashboard URLs. The token now only ever leaves via /api/ha/pair. Keep
// it that way: this payload is also served unauthenticated on the LAN listener.
func (s *server) handleInfo(w http.ResponseWriter, r *http.Request) {
	haURL, _ := readHAURL()
	writeJSON(w, http.StatusOK, map[string]string{
		"name":       deviceName(),
		"hostname":   hostname(),
		"mac":        primaryMAC(),
		"ip":         primaryIP(),
		"machine_id": machineID(),
		"node_id":    s.ha.nodeID,
		"model":      readModel(),
		"serial":     readSerial(),
		"version":    installedVersion(),
		"ha_url":     haURL,
		// The API endpoint the Home Assistant integration connects to. The token it
		// needs is handed over by /api/ha/pair, never printed here.
		"api_url": fmt.Sprintf("http://%s%s", primaryIP(), apiPort()),
	})
}

// apiPort returns the ":<port>" suffix of the HA API listener, for the api_url
// reported by handleInfo.
func apiPort() string {
	addr := envOr("DASHBOARD_ASSISTANT_API_ADDR", ":8081")
	if _, port, err := net.SplitHostPort(addr); err == nil && port != "" {
		return ":" + port
	}
	return addr
}

// watchDisplayState tails the reverse FIFO, reporting each "on"/"off" line the
// in-session agents write into the Display (which broadcasts over SSE). The
// FIFO is opened O_RDWR so the daemon always keeps a writer fd of its own —
// reads then block for data instead of hitting EOF each time a writer closes,
// and writers never get ENXIO for a missing reader. Reopens on any error.
func watchDisplayState(disp *Display, act *Activity) {
	for {
		f, err := os.OpenFile(displayStateFifo, os.O_RDWR, 0)
		if err != nil {
			log.Printf("display-state: open %s: %v", displayStateFifo, err)
			time.Sleep(time.Second)
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			switch {
			case line == "on":
				disp.Report(true)
			case line == "off":
				disp.Report(false)
			case line == "touch":
				act.Touch()
			case strings.HasPrefix(line, "bright "):
				if n, err := strconv.Atoi(strings.TrimSpace(line[len("bright "):])); err == nil {
					disp.ReportBrightness(n)
				}
			}
		}
		if err := sc.Err(); err != nil {
			log.Printf("display-state: read %s: %v", displayStateFifo, err)
		}
		f.Close()
		time.Sleep(time.Second)
	}
}

// watchReadyTransition relaunches the kiosk when the device rises into READY from
// any other state — the network came back, or a seed made the config valid. The
// launcher (kiosk.nix) only reads /api/state once at startup and then execs
// Chromium at a fixed URL, so without this a box that booted offline stays on the
// waiting splash even after it reconnects. Restarting re-runs the state-aware
// launcher (which now picks the dashboard) and, with it, a fresh autologin pass.
//
// It fires only on the rising edge into READY, and re-checks after a short settle
// so a flapping link doesn't thrash the session. The initial state is seeded from
// the current value, so a daemon (re)start while already READY doesn't relaunch.
func watchReadyTransition(srv *server) {
	last := srv.deriveState()
	for range time.Tick(3 * time.Second) {
		// Once the link is up, remember it — future offline spells are "reconnecting",
		// not a first-time "connecting". Idempotent after the first write.
		if srv.nm != nil && srv.nm.Connected() {
			markOnline()
		}
		cur := srv.deriveState()
		if cur == StateReady && last != StateReady {
			time.Sleep(2 * time.Second) // let the link settle before disrupting the session
			if srv.deriveState() != StateReady {
				last = cur
				continue
			}
			log.Printf("kiosk: device READY (was %s) — relaunching into the dashboard", last)
			if err := restartKiosk(); err != nil {
				log.Printf("kiosk: restart on ready: %v", err)
			}
		}
		last = cur
	}
}

// loopbackOnly rejects requests that did not originate from the local host.
func loopbackOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func serveEmbedded(w http.ResponseWriter, name string) {
	b, err := webFS.ReadFile(name)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeText(w http.ResponseWriter, code int, s string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(code)
	_, _ = w.Write([]byte(s))
}
