package main

// Home Assistant integration transport. The daemon exposes the dashboard's
// capabilities (display, pages, zoom, theme, screenshot, power, update) and its
// sensors over an authenticated LAN HTTP API, plus a Server-Sent Events stream
// that pushes a full state snapshot whenever anything changes. The first-party
// HACS custom integration (../integration) polls this API and subscribes to the
// stream; there is no MQTT broker.
//
// The API runs on its own listener (DASHBOARD_ASSISTANT_API_ADDR, default :8081,
// opened on the LAN by modules/core/ha-api.nix), mirroring the diagnostics
// listener. Every request carries a bearer token; the primary :8080 admin
// surface stays loopback-only. See daemon/diag.go for the sibling pattern.

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// loadAPIToken returns the device's HA API token: the environment
// (DASHBOARD_ASSISTANT_API_TOKEN, from a Nix EnvironmentFile) wins, then the
// runtime state file written by config import, then a freshly generated token
// persisted on first start. Auto-generation makes the device usable out of the
// box — the token is shown on the loopback Config screen to paste into HA.
func loadAPIToken() string {
	if v := strings.TrimSpace(os.Getenv("DASHBOARD_ASSISTANT_API_TOKEN")); v != "" {
		return v
	}
	if b, err := os.ReadFile(apiTokenFile); err == nil {
		if v := strings.TrimSpace(string(b)); v != "" {
			return v
		}
	}
	tok := randomToken()
	if err := writeAPIToken(tok); err != nil {
		log.Printf("ha: persist api token: %v", err)
	}
	return tok
}

// writeAPIToken atomically stores the API token. Mode 0640: it grants control of
// the device, so it stays a secret readable by the daemon and the shared
// `dashboard` group, like the HA token — not world-readable.
func writeAPIToken(tok string) error {
	tmp := apiTokenFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(tok+"\n"), 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, apiTokenFile)
}

// randomToken returns a 48-hex-char (24-byte) token from a crypto source.
func randomToken() string {
	var b [24]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// nodeID derives a stable id from the machine-id (falling back to the hostname),
// so a device keeps the same HA device/entities across reboots. It is the HA
// device identifier and the unique_id namespace, as the MQTT node id was.
// Machine-id (not the MAC) so a box with two NICs has one unambiguous identity.
func nodeID() string {
	if b, err := os.ReadFile("/etc/machine-id"); err == nil {
		if id := strings.TrimSpace(string(b)); id != "" {
			return "da_" + id[:min(12, len(id))]
		}
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return "da_" + h
	}
	return "da"
}

// deviceName is the friendly HA/UI label: "Dashboard Assistant (<mac6>)", or
// plain "Dashboard Assistant" when no MAC is available. The MAC suffix (matching
// the hostname) distinguishes multiple kiosks without exposing the raw node id.
func deviceName() string {
	if s := macSuffix(); s != "" {
		return "Dashboard Assistant (" + s + ")"
	}
	return "Dashboard Assistant"
}

// stateSnapshot is the full device state the API serves (GET /state) and pushes
// over SSE. It folds in every value the MQTT bridge used to publish as separate
// topics; the integration maps each field to an HA entity.
type stateSnapshot struct {
	Device struct {
		Name     string `json:"name"`
		NodeID   string `json:"node_id"`
		Hostname string `json:"hostname"`
		MAC      string `json:"mac"`
		Model    string `json:"model"`
		Serial   string `json:"serial"`
		Version  string `json:"version"`
	} `json:"device"`
	Display struct {
		On         bool `json:"on"`
		Brightness int  `json:"brightness"`
	} `json:"display"`
	Page struct {
		Current string   `json:"current"`
		Options []string `json:"options"`
		Slots   []string `json:"slots"`
	} `json:"page"`
	TouchSeconds int `json:"touch_seconds"`
	Memory       struct {
		TotalMiB int `json:"total_mib"`
		UsedMiB  int `json:"used_mib"`
	} `json:"memory"`
	Disk struct {
		TotalGiB float64 `json:"total_gib"`
		UsedGiB  float64 `json:"used_gib"`
	} `json:"disk"`
	Generations int `json:"generations"`
	Update      struct {
		Installed   string `json:"installed_version"`
		Latest      string `json:"latest_version"`
		InProgress  bool   `json:"in_progress"`
		URL         string `json:"release_url,omitempty"`
		Title       string `json:"title,omitempty"`
		Summary     string `json:"release_summary,omitempty"`
		Installable bool   `json:"installable"`
	} `json:"update"`
	Zoom  int `json:"zoom"`
	Theme struct {
		Dark bool `json:"dark"`
	} `json:"theme"`
	Rotation struct {
		Current int   `json:"current"`
		Options []int `json:"options"`
	} `json:"rotation"`
	Host struct {
		IP     string `json:"ip"`
		Uptime int    `json:"uptime"`
		CPU    int    `json:"cpu"`
	} `json:"host"`
	Battery struct {
		Present  bool `json:"present"`
		Level    int  `json:"level"`
		Charging bool `json:"charging"`
	} `json:"battery"`
	Temperature struct {
		Present bool    `json:"present"`
		Celsius float64 `json:"celsius"`
	} `json:"temperature"`
	Screenshot struct {
		Available bool  `json:"available"`
		UpdatedAt int64 `json:"updated_at,omitempty"`
	} `json:"screenshot"`
}

// HAHub owns the capability objects and the live SSE subscribers, and caches the
// latest screenshot. It replaces the MQTT bridge/manager: the same object
// observers that used to trigger MQTT republishes now trigger an SSE broadcast.
type HAHub struct {
	token  string
	nodeID string
	pair   *Pairing // presence-gated, typing-free token hand-off (see pairing.go)

	disp  *Display
	pages *Pages
	act   *Activity
	upd   *UpdateChecker
	zoom  *Zoom
	theme *Theme
	rot   *Rotation

	mu   sync.Mutex
	subs map[chan []byte]struct{}

	shotMu sync.Mutex
	shot   []byte
	shotAt time.Time
}

// NewHAHub wires the object observers to broadcast a fresh snapshot to every SSE
// subscriber, keeping HA in sync with both API commands and out-of-band changes
// reported over the reverse channel (display power, touch, brightness).
func NewHAHub(token string, disp *Display, pages *Pages, act *Activity, upd *UpdateChecker, zoom *Zoom, theme *Theme, rot *Rotation) *HAHub {
	h := &HAHub{
		token:  token,
		nodeID: nodeID(),
		pair:   NewPairing(token),
		disp:   disp,
		pages:  pages,
		act:    act,
		upd:    upd,
		zoom:   zoom,
		theme:  theme,
		rot:    rot,
		subs:   map[chan []byte]struct{}{},
	}
	obs := func() { h.broadcast() }
	disp.SetObserver(obs)
	pages.SetObserver(obs)
	act.SetObserver(obs)
	upd.SetObserver(obs)
	zoom.SetObserver(obs)
	theme.SetObserver(obs)
	rot.SetObserver(obs)
	return h
}

// Broadcast marshals the current snapshot and pushes it to every subscriber. It
// is also the periodic-telemetry entry point (called on the ticker in main), so
// climbing counters (touch, uptime) and sampled sensors (cpu, memory) refresh.
// Sends are non-blocking: a lagging subscriber simply drops the frame.
func (h *HAHub) broadcast() {
	data, err := json.Marshal(h.snapshot())
	if err != nil {
		log.Printf("ha: marshal snapshot: %v", err)
		return
	}
	h.mu.Lock()
	for ch := range h.subs {
		select {
		case ch <- data:
		default:
		}
	}
	h.mu.Unlock()
}

func (h *HAHub) subscribe() chan []byte {
	ch := make(chan []byte, 4)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *HAHub) unsubscribe(ch chan []byte) {
	h.mu.Lock()
	delete(h.subs, ch)
	h.mu.Unlock()
}

// snapshot reads the current state from every capability object and system probe.
// Battery/temperature carry a Present flag (from the existing readBattery/
// readTemperature ok result) so the integration only creates those entities on
// hardware that has them.
func (h *HAHub) snapshot() stateSnapshot {
	var s stateSnapshot

	s.Device.Name = deviceName()
	s.Device.NodeID = h.nodeID
	s.Device.Hostname = hostname()
	s.Device.MAC = primaryMAC()
	s.Device.Model = readModel()
	s.Device.Serial = readSerial()
	s.Device.Version = installedVersion()

	s.Display.On = h.disp.On()
	s.Display.Brightness = h.disp.Brightness()

	s.Page.Current = h.pages.CurrentLabel()
	s.Page.Options = h.pages.Labels()
	slots := make([]string, pageSlots)
	for i := range slots {
		slots[i] = h.pages.Slot(i)
	}
	s.Page.Slots = slots

	s.TouchSeconds = h.act.SecondsSince()

	if total, used, err := readMem(); err == nil {
		s.Memory.TotalMiB, s.Memory.UsedMiB = total, used
	}
	if total, used, err := readDisk(); err == nil {
		s.Disk.TotalGiB, s.Disk.UsedGiB = total, used
	}
	if gens, err := listGenerations(); err == nil {
		s.Generations = len(gens)
	}

	us := h.upd.State()
	s.Update.Installed = us.Installed
	s.Update.Latest = us.Latest
	s.Update.InProgress = us.InProgress
	s.Update.URL = us.URL
	s.Update.Title = us.Title
	s.Update.Summary = us.Summary
	s.Update.Installable = h.upd.Installable()

	s.Zoom = h.zoom.Level()
	s.Theme.Dark = h.theme.Dark()
	s.Rotation.Current = h.rot.Degrees()
	s.Rotation.Options = h.rot.Options()

	s.Host.IP = primaryIP()
	if up, err := readUptime(); err == nil {
		s.Host.Uptime = up
	}
	if pct, err := cpu.Usage(); err == nil {
		s.Host.CPU = pct
	}

	if pct, charging, ok := readBattery(); ok {
		s.Battery.Present = true
		s.Battery.Level = pct
		s.Battery.Charging = charging
	}
	if c, ok := readTemperature(); ok {
		s.Temperature.Present = true
		s.Temperature.Celsius = c
	}

	h.shotMu.Lock()
	if len(h.shot) > 0 {
		s.Screenshot.Available = true
		s.Screenshot.UpdatedAt = h.shotAt.Unix()
	}
	h.shotMu.Unlock()

	return s
}

// routes builds the authenticated API mux served on the LAN listener.
func (h *HAHub) routes() http.Handler {
	mux := http.NewServeMux()
	// Unauthenticated on purpose: the gate is the pairing window, not a token the
	// caller does not have yet. See handlePair.
	mux.HandleFunc("/api/ha/pair", h.handlePair)
	// Unauthenticated, side-effect free: the stable identity the config flow keys
	// zeroconf discovery on, so one device is one Home Assistant entry.
	mux.HandleFunc("/api/ha/identify", h.handleIdentify)
	mux.HandleFunc("/api/ha/info", h.auth(h.handleInfo))
	mux.HandleFunc("/api/ha/kiosk_login", h.auth(h.handleKioskLogin))
	mux.HandleFunc("/api/ha/state", h.auth(h.handleStateSnapshot))
	mux.HandleFunc("/api/ha/events", h.auth(h.handleEvents))
	mux.HandleFunc("/api/ha/display", h.auth(h.handleDisplay))
	mux.HandleFunc("/api/ha/page", h.auth(h.handlePage))
	mux.HandleFunc("/api/ha/page_slot", h.auth(h.handlePageSlot))
	mux.HandleFunc("/api/ha/zoom", h.auth(h.handleZoom))
	mux.HandleFunc("/api/ha/theme", h.auth(h.handleTheme))
	mux.HandleFunc("/api/ha/rotation", h.auth(h.handleRotation))
	mux.HandleFunc("/api/ha/power", h.auth(h.handlePower))
	mux.HandleFunc("/api/ha/reset", h.auth(h.handleReset))
	mux.HandleFunc("/api/ha/update", h.auth(h.handleUpdate))
	mux.HandleFunc("/api/ha/screenshot", h.auth(h.handleScreenshot))
	mux.HandleFunc("/api/ha/screenshot.jpg", h.auth(h.handleScreenshotImage))
	return mux
}

// serveHAAPI runs the LAN HA API listener. Mirrors serveDiag: its own address,
// its own mux, separate from the loopback :8080 admin surface.
func serveHAAPI(hub *HAHub) {
	addr := envOr("DASHBOARD_ASSISTANT_API_ADDR", ":8081")
	log.Printf("ha api listening on %s (node %s)", addr, hub.nodeID)
	if err := http.ListenAndServe(addr, hub.routes()); err != nil {
		log.Printf("ha api server error: %v", err)
	}
}

// auth gates a handler behind the bearer token, compared in constant time.
func (h *HAHub) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		const prefix = "Bearer "
		got := r.Header.Get("Authorization")
		if !strings.HasPrefix(got, prefix) ||
			subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(got, prefix)), []byte(h.token)) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// handlePair hands the API token to Home Assistant without anyone reading or
// typing it. It is deliberately unauthenticated — the caller does not yet have a
// token; the gate is the pairing window, which only opens when the operator
// presses "Pair" on the loopback Config screen (physical presence) or when the
// build auto-confirms (preseeded fleet). Outside the window it reveals nothing.
func (h *HAHub) handlePair(w http.ResponseWriter, r *http.Request) {
	if !requirePost(w, r) {
		return
	}
	tok, ok := h.pair.Claim()
	if !ok {
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": "pairing not open; press Pair on the device's Config screen",
		})
		return
	}
	log.Printf("ha: device paired via on-screen confirmation")
	writeJSON(w, http.StatusOK, map[string]any{
		"token":   tok,
		"node_id": h.nodeID,
		"name":    deviceName(),
	})
}

// handleKioskLogin stages a Home Assistant login for the kiosk so no one has to
// type credentials on the device. The integration creates a dedicated HA user
// and a long-lived token, then posts it here; the daemon persists the token (and
// the dashboard URL, if given) exactly as a seed import would and relaunches the
// kiosk, whose autologin injector signs the browser in on the next start. It
// reuses the same staging the loopback /api/import uses, so no new kiosk plumbing
// is needed. Authenticated with the device token like every other command.
func (h *HAHub) handleKioskLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
		HAURL string `json:"ha_url"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.Token) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "token required"})
		return
	}

	applied := []string{"token"}
	if err := writeToken(req.Token); err != nil {
		writeErr(w, err)
		return
	}
	// An explicit dashboard URL is optional — without one the kiosk falls back to
	// its built-in default. Store it when given.
	if u := strings.TrimSpace(req.HAURL); u != "" {
		if err := writeHAURL(u); err != nil {
			writeErr(w, err)
			return
		}
		applied = append(applied, "ha_url")
	}
	// Being handed a login means Home Assistant has added this device, so mark it
	// provisioned — it leaves the add screen for the dashboard even if no URL was
	// pushed (the kiosk then uses the default).
	if err := markProvisioned(); err != nil {
		writeErr(w, err)
		return
	}

	log.Printf("ha: kiosk login staged (%v); relaunching kiosk", applied)
	// Relaunch so the autologin injector picks up the freshly staged token. Async:
	// tearing down the session can outlive this request.
	go func() {
		if err := restartKiosk(); err != nil {
			log.Printf("ha: restart kiosk after login: %v", err)
		}
	}()
	writeJSON(w, http.StatusOK, map[string]any{"applied": applied})
}

// handleIdentify returns the device's stable identity for zeroconf de-dup. It is
// unauthenticated and side-effect free, exposing only the node id and friendly
// name (both already implied by the mDNS advertisement) — no secrets. The config
// flow calls it during discovery so every address the device is found at maps to
// one entry, and a later DHCP address change updates that entry instead of adding
// a duplicate.
func (h *HAHub) handleIdentify(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"node_id": h.nodeID,
		"name":    deviceName(),
	})
}

// handleInfo returns device identity + capabilities. The config flow calls it to
// validate the token and derive the HA device unique id (node_id).
func (h *HAHub) handleInfo(w http.ResponseWriter, r *http.Request) {
	_, _, hasBattery := readBattery()
	_, hasTemp := readTemperature()
	writeJSON(w, http.StatusOK, map[string]any{
		"name":            deviceName(),
		"node_id":         h.nodeID,
		"hostname":        hostname(),
		"mac":             primaryMAC(),
		"model":           readModel(),
		"serial":          readSerial(),
		"version":         installedVersion(),
		"installable":     h.upd.Installable(),
		"has_battery":     hasBattery,
		"has_temperature": hasTemp,
	})
}

func (h *HAHub) handleStateSnapshot(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handleEvents streams state snapshots as SSE: the current state on connect, then
// a fresh snapshot on every change (and on the telemetry ticker). Keep-alive
// comments hold the connection open through idle periods.
func (h *HAHub) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := h.subscribe()
	defer h.unsubscribe(ch)

	if data, err := json.Marshal(h.snapshot()); err == nil {
		writeSSE(w, data)
		fl.Flush()
	}

	ka := time.NewTicker(25 * time.Second)
	defer ka.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case data := <-ch:
			writeSSE(w, data)
			fl.Flush()
		case <-ka.C:
			io.WriteString(w, ": keep-alive\n\n")
			fl.Flush()
		}
	}
}

func writeSSE(w io.Writer, data []byte) {
	io.WriteString(w, "data: ")
	w.Write(data)
	io.WriteString(w, "\n\n")
}

// handleDisplay drives the display light: on/off and/or brightness (0..100).
// Brightness is applied first and implies power-on, matching HA's light: turning
// on with a brightness sends both.
func (h *HAHub) handleDisplay(w http.ResponseWriter, r *http.Request) {
	var req struct {
		On         *bool `json:"on"`
		Brightness *int  `json:"brightness"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Brightness != nil {
		if !h.disp.On() {
			if err := h.disp.Set(true); err != nil {
				log.Printf("ha: display power-on for brightness: %v", err)
			}
		}
		if err := h.disp.SetBrightness(*req.Brightness); err != nil {
			writeErr(w, err)
			return
		}
	}
	if req.On != nil {
		if err := h.disp.Set(*req.On); err != nil {
			writeErr(w, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handlePage jumps to a page by label ({"select": "..."}) or cycles
// ({"dir": "next"|"prev"}).
func (h *HAHub) handlePage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Select string `json:"select"`
		Dir    string `json:"dir"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	switch {
	case req.Select != "":
		h.pages.Select(req.Select)
	case req.Dir == "next":
		h.pages.Next()
	case req.Dir == "prev":
		h.pages.Prev()
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "select or dir (next/prev) required"})
		return
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handlePageSlot edits one "Page N" slot ({"index": i, "value": "Name | URL"}).
func (h *HAHub) handlePageSlot(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Index int    `json:"index"`
		Value string `json:"value"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := h.pages.SetSlot(req.Index, req.Value); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handleZoom sets an absolute browser zoom percent (clamped to 25..400 by Set).
func (h *HAHub) handleZoom(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Percent int `json:"percent"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := h.zoom.Set(req.Percent); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handleTheme switches the browser between dark (true) and light (false).
func (h *HAHub) handleTheme(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Dark bool `json:"dark"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if err := h.theme.Set(req.Dark); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handleRotation sets the display orientation in degrees ({"degrees": 0|90|180|
// 270}). An unsupported angle is a client error; a session-not-ready failure from
// Set (the kiosk isn't up yet) is a server error, mirroring handleZoom — the
// persisted angle is still restored on the next launch.
func (h *HAHub) handleRotation(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Degrees int `json:"degrees"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validRotation(req.Degrees) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "degrees must be one of 0, 90, 180, 270"})
		return
	}
	if err := h.rot.Set(req.Degrees); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, h.snapshot())
}

// handlePower reboots or shuts the device down. Fire-and-forget: a successful
// call tears the daemon down with the system, so we answer optimistically.
func (h *HAHub) handlePower(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	var err error
	switch req.Action {
	case "reboot":
		log.Printf("ha: reboot requested")
		err = systemReboot()
	case "shutdown":
		log.Printf("ha: shutdown requested")
		err = systemPowerOff()
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "action must be reboot or shutdown"})
		return
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": req.Action})
}

// handleReset factory-resets the device: it clears the provisioning + config
// state (HA URL, kiosk login token, device API token, prefs) and reboots, so the
// box comes back on the onboarding screen ready to be added again. Because the
// API token is regenerated on the next boot, Home Assistant's current entry stops
// working — remove it and re-add (re-pair) the device. The node id is preserved,
// so it re-adds as the same device, not a duplicate.
func (h *HAHub) handleReset(w http.ResponseWriter, r *http.Request) {
	if !requirePost(w, r) {
		return
	}
	if err := clearProvisioningState(); err != nil {
		writeErr(w, err)
		return
	}
	log.Printf("ha: factory reset — provisioning cleared, rebooting")
	writeJSON(w, http.StatusOK, map[string]string{"status": "resetting"})
	// Reboot after the response flushes so the caller gets its 200 before the box
	// goes down; the fresh boot regenerates the API token and shows onboarding.
	go func() {
		time.Sleep(time.Second)
		if err := systemReboot(); err != nil {
			log.Printf("ha: reboot after reset: %v", err)
		}
	}()
}

// handleUpdate applies the latest release (reuses the update state machine). It
// marks the entity in-progress, starts the privileged unit, and refreshes state
// from the job result over the SSE broadcast.
func (h *HAHub) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if !requirePost(w, r) {
		return
	}
	tag, ok := h.upd.InstallTarget()
	if !ok {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "no newer release available"})
		return
	}

	h.upd.SetInstalling(true)
	h.broadcast()
	log.Printf("ha: installing update %s", tag)

	err := startUpdate(tag, func(result string) {
		h.upd.SetInstalling(false)
		if result == "done" {
			h.upd.RefreshInstalled()
		} else {
			log.Printf("ha: update %s did not complete: %s", tag, result)
		}
		h.broadcast()
	})
	if err != nil {
		h.upd.SetInstalling(false)
		h.broadcast()
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "installing", "target": tag})
}

// handleScreenshot grabs the whole kiosk screen (in-session grim) and caches the
// JPEG, which the image entity then fetches from screenshot.jpg.
func (h *HAHub) handleScreenshot(w http.ResponseWriter, r *http.Request) {
	if !requirePost(w, r) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	img, err := captureScreenshot(ctx)
	if err != nil {
		writeErr(w, err)
		return
	}
	h.shotMu.Lock()
	h.shot = img
	h.shotAt = time.Now()
	h.shotMu.Unlock()
	h.broadcast()
	writeJSON(w, http.StatusOK, map[string]any{"available": true, "bytes": len(img)})
}

// handleScreenshotImage serves the most recent captured JPEG.
func (h *HAHub) handleScreenshotImage(w http.ResponseWriter, r *http.Request) {
	h.shotMu.Lock()
	img := h.shot
	at := h.shotAt
	h.shotMu.Unlock()
	if len(img) == 0 {
		http.Error(w, "no screenshot yet", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Last-Modified", at.UTC().Format(http.TimeFormat))
	_, _ = w.Write(img)
}

// requirePost rejects non-POST requests with 405.
func requirePost(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return false
	}
	return true
}

// decodeJSON enforces POST and decodes the JSON body into v, writing the error
// response itself and returning false on any failure.
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if !requirePost(w, r) {
		return false
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return false
	}
	return true
}

func writeErr(w http.ResponseWriter, err error) {
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
}
