// Command dashboard-assistant-api is the management daemon for Dashboard Assistant OS.
//
// It owns first-boot provisioning: it computes the device state (SETUP /
// RECONNECT / READY) that the Cage/Chromium launcher polls, serves the
// on-screen setup wizard, and drives NetworkManager over D-Bus to join Wi-Fi.
package main

import (
	"bufio"
	"embed"
	"encoding/json"
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
	StateSetup     State = "SETUP"     // fresh device — show the wizard
	StateReconnect State = "RECONNECT" // provisioned but offline — show splash
	StateReady     State = "READY"     // provisioned and online — show HA
)

type server struct {
	nm    *NetworkManager // nil if no Wi-Fi device / D-Bus unavailable
	mqtt  *MQTTManager    // owns the runtime-reconfigurable MQTT bridge
	pages *Pages          // the pushable page list + current index
	diag  *diagSession    // one-time code for the opt-in LAN diagnostics page
}

// deriveState implements the first-boot decision flow.
func (s *server) deriveState() State {
	if !Provisioned() {
		return StateSetup
	}
	if s.nm == nil || !s.nm.Connected() {
		return StateReconnect
	}
	if !ConfigValid() {
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
	srv := &server{nm: nm, mqtt: NewMQTTManager(disp, pages, act, upd, zoom, theme), pages: pages, diag: newDiagSession()}

	// MQTT bridge to Home Assistant (opt-in: disabled unless a broker is set).
	// Settings come from the environment overlaid by the runtime state file the
	// setup UI / config import write, so this also picks up later changes.
	srv.mqtt.Apply(loadMQTTConfig())

	// Reverse channel: the in-session agents report the real display power state
	// and touch activity here, keeping HA in sync with changes that never went
	// through an MQTT command.
	go watchDisplayState(disp, act)

	// Poll the release source for the latest version; the checker fires the MQTT
	// bridge's observer to republish the update entity whenever it changes.
	go upd.Run()

	// Refresh the periodic sensors on a ticker: the touch counter (so it climbs
	// while idle; touches reset it to 0 immediately via the observer) and memory.
	go func() {
		for range time.Tick(10 * time.Second) {
			srv.mqtt.PublishTelemetry()
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeText(w, http.StatusOK, "ok")
	})
	mux.HandleFunc("/api/state", srv.handleState)

	// On-device admin panel + waiting splash — loopback only (the kiosk browser
	// is local). Provisioning is seed-only (see /api/import); the panel exposes
	// just the read-only Info and Recovery tabs, nothing that re-points the kiosk.
	mux.Handle("/setup", loopbackOnly(http.HandlerFunc(srv.handleSetupPage)))
	mux.Handle("/waiting", loopbackOnly(http.HandlerFunc(srv.handleWaitingPage)))
	// Import a YAML config bundle (HA URL / token / Wi-Fi / MQTT / pages), fed by
	// the USB and ESP importers. Loopback only. This is the sole config path.
	mux.Handle("/api/import", loopbackOnly(http.HandlerFunc(srv.handleImport)))
	// Page navigation (waybar Prev/Next buttons). The page list itself is managed
	// over MQTT (the "Page N" text slots), not through the web UI.
	mux.Handle("/api/nav", loopbackOnly(http.HandlerFunc(srv.handleNav)))
	// Read-only device info for the setup UI's Info tab (identity + network).
	mux.Handle("/api/info", loopbackOnly(http.HandlerFunc(srv.handleInfo)))
	// Recovery: list bootable generations and roll back into one (reboots).
	mux.Handle("/api/generations", loopbackOnly(http.HandlerFunc(srv.handleGenerations)))
	mux.Handle("/api/rollback", loopbackOnly(http.HandlerFunc(srv.handleRollback)))

	// Opt-in LAN diagnostics (modules/core/diagnostics.nix sets the env). The code
	// is minted here on the loopback panel; the redacted logs are served on a
	// separate LAN listener below so :8080 stays loopback-only.
	if diagEnabled() {
		mux.Handle("/api/diag/session", loopbackOnly(http.HandlerFunc(srv.handleDiagSession)))
		go serveDiag(srv)
	}

	mux.HandleFunc("/", srv.handleRoot)

	log.Printf("dashboard-assistant-api listening on %s (state=%s)", addr, srv.deriveState())
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// diagEnabled reports whether the opt-in LAN diagnostics feature is on.
func diagEnabled() bool { return os.Getenv("DASHBOARD_ASSISTANT_DIAG") == "1" }

// serveDiag runs the dedicated LAN diagnostics listener: only the code-entry
// page and the code-gated log endpoint, nothing from the admin surface.
func serveDiag(srv *server) {
	addr := envOr("DASHBOARD_ASSISTANT_DIAG_ADDR", ":8099")
	dmux := http.NewServeMux()
	dmux.HandleFunc("/diag", srv.handleDiagPage)
	dmux.HandleFunc("/api/diag", srv.handleDiagData)
	log.Printf("diagnostics listening on %s", addr)
	if err := http.ListenAndServe(addr, dmux); err != nil {
		log.Printf("diagnostics server error: %v", err)
	}
}

func (s *server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	// Point a human who hits the daemon directly at the waiting splash. Fresh
	// devices are provisioned from a seed file, not an on-screen wizard, so there
	// is nothing interactive to send them to; /setup is the admin panel reached
	// via the on-screen Config button.
	http.Redirect(w, r, "/waiting", http.StatusFound)
}

func (s *server) handleState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"state": string(s.deriveState())})
}

func (s *server) handleSetupPage(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "web/setup.html")
}

func (s *server) handleWaitingPage(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "web/waiting.html")
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

// handleInfo returns read-only device identity + network details for the setup
// UI's Info tab. The node id / machine id are surfaced here (rather than in the
// device name) so they're discoverable without cluttering the label.
func (s *server) handleInfo(w http.ResponseWriter, r *http.Request) {
	haURL, _ := readHAURL()
	writeJSON(w, http.StatusOK, map[string]string{
		"name":       deviceName(),
		"hostname":   hostname(),
		"mac":        primaryMAC(),
		"ip":         primaryIP(),
		"machine_id": machineID(),
		"node_id":    loadMQTTConfig().NodeID,
		"model":      readModel(),
		"serial":     readSerial(),
		"version":    installedVersion(),
		"ha_url":     haURL,
	})
}

// handleGenerations lists the bootable NixOS generations for the recovery UI.
func (s *server) handleGenerations(w http.ResponseWriter, r *http.Request) {
	gens, err := listGenerations()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"generations": gens, "current": currentGeneration()})
}

// handleRollback boots into the requested generation (switches the profile and
// reboots, via the privileged dashboard-assistant-rollback@ unit). POST {"generation": N}.
func (s *server) handleRollback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	var req struct {
		Generation int `json:"generation"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	if !generationExists(req.Generation) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no such generation"})
		return
	}
	if req.Generation == currentGeneration() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "already the current generation"})
		return
	}
	if err := bootGeneration(req.Generation); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	log.Printf("rollback: booting generation %d", req.Generation)
	writeJSON(w, http.StatusOK, map[string]any{"state": "rebooting", "generation": req.Generation})
}

// watchDisplayState tails the reverse FIFO, reporting each "on"/"off" line the
// in-session agents write into the Display (which republishes over MQTT). The
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
