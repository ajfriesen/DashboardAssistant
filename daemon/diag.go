package main

// LAN diagnostics: a read-only, secret-redacted view of recent logs that a user
// can open from their own phone/laptop to hand to the maintainer. The kiosk is
// locked to Home Assistant and has no SSH, so there is otherwise no way to get
// logs off the device.
//
// It runs on a dedicated listener (see main.go), only when enabled via the
// DASHBOARD_ASSISTANT_DIAG env (set by modules/core/diagnostics.nix), and is
// gated by a one-time code minted on the on-screen (loopback) Config panel. The
// primary :8080 admin surface stays loopback-only.

import (
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// diagTTL is how long a minted diagnostics code stays valid.
const diagTTL = 15 * time.Minute

// diagMaxTries caps guesses against a live code within its TTL window.
const diagMaxTries = 20

// diagSession holds the current one-time code for LAN diagnostics access. Only
// one code is live at a time; minting a new one supersedes the old.
type diagSession struct {
	mu      sync.Mutex
	code    string
	expires time.Time
	tries   int
}

func newDiagSession() *diagSession { return &diagSession{} }

// mint generates a fresh 6-digit code with a TTL and returns it, resetting the
// guess counter.
func (d *diagSession) mint() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.code = randomCode()
	d.expires = time.Now().Add(diagTTL)
	d.tries = 0
	return d.code
}

// valid reports whether code matches the live, unexpired code (constant-time),
// with a coarse rate limit on failed attempts.
func (d *diagSession) valid(code string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.code == "" || time.Now().After(d.expires) {
		return false
	}
	if d.tries >= diagMaxTries {
		return false
	}
	d.tries++
	return subtle.ConstantTimeCompare([]byte(code), []byte(d.code)) == 1
}

// randomCode returns a zero-padded 6-digit code from a crypto source.
func randomCode() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	n := (uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])) % 1000000
	return fmt.Sprintf("%06d", n)
}

// handleDiagSession (loopback, on-screen Config panel) mints a one-time code and
// returns it with the LAN URL the user opens on their phone. POST only.
func (s *server) handleDiagSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	code := s.diag.mint()
	// The LAN listener addr is like ":8099"; take its port for the phone URL.
	_, port, err := net.SplitHostPort(envOr("DASHBOARD_ASSISTANT_DIAG_ADDR", ":8099"))
	if err != nil || port == "" {
		port = "8099"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"code":        code,
		"url":         fmt.Sprintf("http://%s:%s/diag", primaryIP(), port),
		"ttl_seconds": int(diagTTL.Seconds()),
	})
}

// handleDiagPage serves the public code-entry page (carries no data itself).
func (s *server) handleDiagPage(w http.ResponseWriter, r *http.Request) {
	serveEmbedded(w, "web/diag.html")
}

// handleDiagData returns the redacted diagnostics text, gated by the one-time
// code minted on the kiosk. GET /api/diag?code=NNNNNN.
func (s *server) handleDiagData(w http.ResponseWriter, r *http.Request) {
	if !s.diag.valid(r.URL.Query().Get("code")) {
		http.Error(w, "invalid or expired code", http.StatusForbidden)
		return
	}
	writeText(w, http.StatusOK, diagnosticsText())
}

// diagnosticsText assembles the device identity block plus recent logs, then
// redacts secrets from the whole thing.
func diagnosticsText() string {
	var b strings.Builder
	fmt.Fprintf(&b, "Dashboard Assistant diagnostics\n")
	fmt.Fprintf(&b, "generated: %s\n\n", time.Now().UTC().Format(time.RFC3339))

	haURL, _ := readHAURL()
	b.WriteString("== device ==\n")
	for _, kv := range [][2]string{
		{"name", deviceName()},
		{"hostname", hostname()},
		{"ip", primaryIP()},
		{"mac", primaryMAC()},
		{"machine_id", machineID()},
		{"model", readModel()},
		{"serial", readSerial()},
		{"version", installedVersion()},
		{"ha_url", haURL},
		{"node_id", nodeID()},
	} {
		fmt.Fprintf(&b, "%-13s %s\n", kv[0]+":", kv[1])
	}

	b.WriteString("\n== logs ==\n")
	b.WriteString(readJournal())
	return redact(b.String())
}

// readJournal returns the recent journal for the daemon, the kiosk session, and
// the boot/rollback units. journalctl treats an unknown unit as empty output, so
// the glob is safe even as unit names change.
func readJournal() string {
	jctl := envOr("DASHBOARD_ASSISTANT_JOURNALCTL", "journalctl")
	out, err := exec.Command(jctl,
		"--no-pager", "-n", "1500",
		"-u", "dashboard-assistant-*",
		"-u", "greetd",
	).CombinedOutput()
	if err != nil {
		return fmt.Sprintf("(journalctl failed: %v)\n%s", err, out)
	}
	return string(out)
}

// jwtRe matches JWT-shaped tokens (the HA long-lived access token is one).
var jwtRe = regexp.MustCompile(`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)

// kvSecretRe matches key=value / key: value pairs whose key names a secret, so
// their values are dropped even if the daemon doesn't know the exact string.
var kvSecretRe = regexp.MustCompile(`(?i)((?:psk|passwd|password|token|secret)["']?\s*[=:]\s*)\S+`)

// redact removes secrets the daemon knows (the stored HA token and the device
// API token) plus anything matching the generic secret patterns.
func redact(s string) string {
	for _, secret := range knownSecrets() {
		s = strings.ReplaceAll(s, secret, "«redacted»")
	}
	s = jwtRe.ReplaceAllString(s, "«redacted-token»")
	s = kvSecretRe.ReplaceAllString(s, "${1}«redacted»")
	return s
}

// knownSecrets returns the concrete secret values the daemon holds, so they can
// be scrubbed by exact match wherever they appear.
func knownSecrets() []string {
	var out []string
	for _, path := range []string{tokenFile, apiTokenFile} {
		if b, err := os.ReadFile(path); err == nil {
			if tok := strings.TrimSpace(string(b)); tok != "" {
				out = append(out, tok)
			}
		}
	}
	return out
}
