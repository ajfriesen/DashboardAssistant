package main

// The captive portal: the page a phone sees after joining the setup access point.
//
// Getting a portal to *open by itself* is the whole trick, and it rests on
// deliberately failing the connectivity probes every OS fires the moment it gets a
// DHCP lease. Each vendor asks for a specific URL and expects a specific answer;
// serving anything else is the signal that means "there is a portal here". Serving
// *nothing* is the signal that means "this network is broken", which makes phones
// mark it as having no internet and quietly drop back to cellular. So the
// catch-all below must always answer, and always answer wrong:
//
//	iOS/macOS  http://captive.apple.com/hotspot-detect.html   wants a Success body
//	Android    http://connectivitycheck.gstatic.com/generate_204   wants 204
//	Windows    http://www.msftconnecttest.com/connecttest.txt      wants its text
//	Firefox    http://detectportal.firefox.com/canonical.html      wants a meta refresh
//
// Wildcard DNS (the dnsmasq drop-in in modules/core/onboarding.nix) points all of
// those hostnames at this device, and DHCP option 114 from the same file tells
// RFC 8910-aware clients the portal URL outright, which is the only path that
// survives a phone with Private DNS set to strict.
//
// The listener arrives as a socket-activated file descriptor from systemd, bound
// to the AP address with FreeBind. That matters for two reasons: it needs no
// capability in this unit, and FreeBind lets systemd bind the address *before*
// NetworkManager creates it, so the portal is already answering when the first
// probe lands. A listener that starts late loses that first probe, and neither iOS
// nor Android re-probes promptly once they have concluded there is no portal.

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

// servePortal runs the AP-side HTTP listener for as long as the daemon lives. The
// socket is scoped to the AP address, so when no AP is up nothing can reach it.
func servePortal(srv *server) {
	ln, err := portalListener()
	if err != nil {
		log.Printf("portal: not serving: %v", err)
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/portal/status", srv.handlePortalStatus)
	mux.HandleFunc("/api/portal/join", srv.handlePortalJoin)
	// Everything else, including every OS probe URL, lands here.
	mux.HandleFunc("/", srv.handlePortalCatchAll)

	log.Printf("portal: listening on %s", ln.Addr())
	server := &http.Server{
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
	if err := server.Serve(ln); err != nil {
		log.Printf("portal: server error: %v", err)
	}
}

// portalListener prefers the fd systemd hands over (LISTEN_FDS), falling back to
// binding directly so the daemon still works outside systemd, in tests and in a
// dev shell. The fallback cannot bind port 80 unprivileged, which is precisely why
// the socket unit exists.
func portalListener() (net.Listener, error) {
	if n, _ := strconv.Atoi(os.Getenv("LISTEN_FDS")); n > 0 &&
		os.Getenv("LISTEN_PID") == strconv.Itoa(os.Getpid()) {
		// systemd passes descriptors starting at 3, in the order the unit lists
		// them. The daemon takes exactly one socket.
		f := os.NewFile(3, "portal")
		ln, err := net.FileListener(f)
		if err == nil {
			return ln, nil
		}
		log.Printf("portal: could not adopt the systemd socket: %v", err)
	}
	addr := envOr("DASHBOARD_ASSISTANT_PORTAL_ADDR", apAddress+":80")
	return net.Listen("tcp", addr)
}

func (s *server) handlePortalStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.onboard.Info())
}

// handlePortalJoin takes the network details and switches the radio over.
//
// Ordering here is not incidental. The phone's association dies the instant the
// radio leaves AP mode, so this response is the last thing it will ever hear from
// the device: it has to be fully written and flushed, with the connection closed,
// before anything touches NetworkManager. Everything after that point reports to
// the tablet's own screen instead.
func (s *server) handlePortalJoin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	var req struct {
		SSID string `json:"ssid"`
		PSK  string `json:"psk"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	if req.SSID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "network name required"})
		return
	}

	w.Header().Set("Connection", "close")
	writeJSON(w, http.StatusOK, map[string]string{"state": "joining", "ssid": req.SSID})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	go func() {
		// Give the flushed response time to reach a phone that is about to lose
		// its association. Without this the user sees a connection error instead
		// of the "joining now" screen and assumes the device crashed.
		time.Sleep(time.Second)
		s.onboard.Join(req.SSID, req.PSK)
	}()
}

// handlePortalCatchAll answers every unrecognised request, which is how the
// portal announces itself. Apple's probe gets the page body directly: its Captive
// Network Assistant renders whatever comes back, and a 200 saves a redirect hop
// inside a restricted webview. Everything else gets a redirect, which is the most
// widely understood "you are behind a portal" answer.
func (s *server) handlePortalCatchAll(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" || r.URL.Path == "/hotspot-detect.html" {
		serveEmbedded(w, "web/portal.html")
		return
	}
	http.Redirect(w, r, "http://"+apAddress+"/", http.StatusFound)
}
