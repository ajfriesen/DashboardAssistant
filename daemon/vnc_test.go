package main

import (
	"bufio"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// newTestVNC points VNC at a temp FIFO (held open read-write, like the
// in-session agent does) and temp state, and returns a reader for the commands
// it sends. The test's "minute" is a few milliseconds so auto-close is testable.
func newTestVNC(t *testing.T) (*VNC, *bufio.Scanner) {
	t.Helper()
	dir := tempState(t)
	fifo := filepath.Join(dir, "vnc.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	t.Setenv("DASHBOARD_ASSISTANT_VNC", "1")
	t.Setenv("DASHBOARD_ASSISTANT_VNC_FIFO", fifo)
	v := NewVNC()
	v.minute = 20 * time.Millisecond
	t.Cleanup(func() { _ = v.Set(false) })
	return v, bufio.NewScanner(f)
}

func readVNCConfig(t *testing.T) map[string]string {
	t.Helper()
	b, err := os.ReadFile(vncConfigFile)
	if err != nil {
		t.Fatalf("read wayvnc config: %v", err)
	}
	cfg := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		if k, val, ok := strings.Cut(line, "="); ok {
			cfg[strings.TrimSpace(k)] = strings.TrimSpace(val)
		}
	}
	return cfg
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestVNCIsOffByDefault(t *testing.T) {
	v, _ := newTestVNC(t)
	if v.On() || v.Password() != "" {
		t.Fatalf("fresh VNC on=%v password=%q, want off with no password", v.On(), v.Password())
	}
	if v.Timeout() != 15 {
		t.Fatalf("default timeout = %d, want 15", v.Timeout())
	}
	if _, err := os.Stat(vncConfigFile); !os.IsNotExist(err) {
		t.Fatal("no wayvnc config may exist before VNC is switched on")
	}
}

func TestVNCOnlyOnBuildsThatShipIt(t *testing.T) {
	tempState(t)
	t.Setenv("DASHBOARD_ASSISTANT_VNC", "")
	v := NewVNC()
	if v.Available() {
		t.Fatal("VNC must not be available without DASHBOARD_ASSISTANT_VNC=1")
	}
	if err := v.Set(true); err == nil {
		t.Fatal("switching on VNC on a build without it must fail")
	}
}

// The config wayvnc starts with is the whole security story: authentication on,
// both encrypted security types configured, and neither of the escape hatches
// that let a client skip encryption.
func TestVNCOnWritesAnEncryptedOnlyConfig(t *testing.T) {
	v, sc := newTestVNC(t)
	if err := v.Set(true); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "start")

	fi, err := os.Stat(vncConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("config mode = %o, want 640: it holds the password", fi.Mode().Perm())
	}

	cfg := readVNCConfig(t)
	want := map[string]string{
		"enable_auth":          "true",
		"address":              "0.0.0.0",
		"port":                 "5900",
		"username":             vncUsername,
		"password":             v.Password(),
		"rsa_private_key_file": vncRSAKeyFile,
		"private_key_file":     vncTLSKeyFile,
		"certificate_file":     vncTLSCertFile,
	}
	for k, w := range want {
		if cfg[k] != w {
			t.Errorf("config %s = %q, want %q", k, cfg[k], w)
		}
	}
	for _, k := range []string{"relax_encryption", "allow_broken_crypto", "enable_pam"} {
		if _, ok := cfg[k]; ok {
			t.Errorf("config must not set %s", k)
		}
	}

	// wayvnc's RSA-AES wants a PKCS#1 RSA key; VeNCrypt wants a cert + key.
	b, err := os.ReadFile(vncRSAKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "RSA PRIVATE KEY" {
		t.Fatalf("RSA key is not a PKCS#1 PEM block")
	}
	if _, err := x509.ParsePKCS1PrivateKey(block.Bytes); err != nil {
		t.Fatalf("RSA key: %v", err)
	}
	if err := checkKeypairFiles(vncTLSCertFile, vncTLSKeyFile); err != nil {
		t.Fatalf("TLS keypair: %v", err)
	}
}

func TestVNCPasswordIsFreshEverySession(t *testing.T) {
	v, sc := newTestVNC(t)
	seen := map[string]bool{}
	for range 5 {
		if err := v.Set(true); err != nil {
			t.Fatal(err)
		}
		expectCmd(t, sc, "start")
		p := v.Password()
		if len(p) < 12 {
			t.Fatalf("password %q is shorter than 12 characters", p)
		}
		if seen[p] {
			t.Fatalf("password %q was reused", p)
		}
		seen[p] = true
		if err := v.Set(false); err != nil {
			t.Fatal(err)
		}
		expectCmd(t, sc, "stop")
	}
}

// Keys survive between sessions, so a VNC client that remembered the server's
// key does not warn about a changed identity every time.
func TestVNCKeysAreKeptBetweenSessions(t *testing.T) {
	v, sc := newTestVNC(t)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	first, _ := os.ReadFile(vncRSAKeyFile)
	_ = v.Set(false)
	expectCmd(t, sc, "stop")
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	second, _ := os.ReadFile(vncRSAKeyFile)
	if string(first) != string(second) {
		t.Fatal("the RSA key changed between sessions")
	}
}

func TestVNCOffStopsAndForgetsThePassword(t *testing.T) {
	v, sc := newTestVNC(t)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	if err := v.Set(false); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "stop")
	if v.On() || v.Password() != "" || !v.ClosesAt().IsZero() {
		t.Fatalf("after off: on=%v password=%q closes_at=%v", v.On(), v.Password(), v.ClosesAt())
	}
	if _, err := os.Stat(vncConfigFile); !os.IsNotExist(err) {
		t.Fatal("the config holding the password must be removed on off")
	}
}

func TestVNCClosesItselfAfterTheTimeout(t *testing.T) {
	v, sc := newTestVNC(t)
	var fired atomic.Int32
	v.SetObserver(func() { fired.Add(1) })
	v.SetTimeout(1)
	if err := v.Set(true); err != nil {
		t.Fatal(err)
	}
	expectCmd(t, sc, "start")
	if v.ClosesAt().IsZero() {
		t.Fatal("closes_at must be set while a timeout applies")
	}
	waitFor(t, "auto-close", func() bool { return !v.On() })
	expectCmd(t, sc, "stop")
	if v.Password() != "" {
		t.Fatal("password survived the auto-close")
	}
	if fired.Load() < 3 { // timeout, on, auto-off
		t.Fatalf("observer fired %d times, want the auto-close broadcast too", fired.Load())
	}
}

func TestVNCTimeoutZeroNeverCloses(t *testing.T) {
	v, sc := newTestVNC(t)
	v.SetTimeout(0)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	if !v.ClosesAt().IsZero() {
		t.Fatal("closes_at must be empty when the timeout is off")
	}
	time.Sleep(5 * v.minute)
	if !v.On() {
		t.Fatal("VNC closed although the timeout is 0 (never)")
	}
}

func TestVNCTimeoutIsClampedAndPersisted(t *testing.T) {
	v, _ := newTestVNC(t)
	v.SetTimeout(10000)
	if v.Timeout() != 240 {
		t.Fatalf("timeout = %d, want clamped to 240", v.Timeout())
	}
	v.SetTimeout(-5)
	if v.Timeout() != 0 {
		t.Fatalf("timeout = %d, want clamped to 0", v.Timeout())
	}
	v.SetTimeout(30)
	if got := NewVNC().Timeout(); got != 30 {
		t.Fatalf("timeout after restart = %d, want 30", got)
	}
}

// Shortening the timeout below the time a session has already run closes it now,
// rather than leaving it open with a countdown that already passed.
func TestVNCShorterTimeoutWhileOnClosesAnOverdueSession(t *testing.T) {
	v, sc := newTestVNC(t)
	v.SetTimeout(0)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	time.Sleep(2 * v.minute)
	v.SetTimeout(1)
	waitFor(t, "close", func() bool { return !v.On() })
	expectCmd(t, sc, "stop")
}

// A timer from an earlier session must not close the next one.
func TestVNCStaleTimerDoesNotCloseANewSession(t *testing.T) {
	v, sc := newTestVNC(t)
	v.SetTimeout(1)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	_ = v.Set(false)
	expectCmd(t, sc, "stop")
	v.SetTimeout(0)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	time.Sleep(3 * v.minute)
	if !v.On() {
		t.Fatal("a stale timer closed the new session")
	}
}

// A restarted daemon has no timer for a wayvnc started by its predecessor, so it
// stops whatever is running and removes the old password.
func TestVNCResetStopsALeftoverServer(t *testing.T) {
	v, sc := newTestVNC(t)
	if err := os.WriteFile(vncConfigFile, []byte("password=old\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	v.Reset()
	expectCmd(t, sc, "stop")
	if _, err := os.Stat(vncConfigFile); !os.IsNotExist(err) {
		t.Fatal("Reset must remove a leftover config")
	}
}

// With no kiosk session there is no wayvnc either, so switching off must succeed.
func TestVNCOffWithoutSession(t *testing.T) {
	tempState(t)
	t.Setenv("DASHBOARD_ASSISTANT_VNC", "1")
	t.Setenv("DASHBOARD_ASSISTANT_VNC_FIFO", filepath.Join(t.TempDir(), "missing.fifo"))
	v := NewVNC()
	if err := v.Set(true); err == nil {
		t.Fatal("switching on without a session must fail")
	}
	if v.On() {
		t.Fatal("a failed start must leave VNC off")
	}
	if err := v.Set(false); err != nil {
		t.Fatalf("off without a session: %v", err)
	}
	v.Reset() // must not panic or block
}

// The session restarted (or wayvnc died): the agent reports it, and the switch
// follows without the daemon sending anything.
func TestVNCReportOff(t *testing.T) {
	v, sc := newTestVNC(t)
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	v.ReportOff()
	if v.On() || v.Password() != "" {
		t.Fatal("ReportOff must mark VNC off and drop the password")
	}
}

func vncRequest(h *HAHub, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/ha/vnc", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	h.routes().ServeHTTP(rec, req)
	return rec
}

func TestVNCEndpointRefusesOnBuildsWithoutIt(t *testing.T) {
	tempState(t)
	t.Setenv("DASHBOARD_ASSISTANT_VNC", "")
	h := &HAHub{token: "tok", pair: NewPairing("tok"), vnc: NewVNC()}
	if rec := vncRequest(h, `{"on": true}`); rec.Code != http.StatusNotFound {
		t.Fatalf("POST /api/ha/vnc = %d, want 404", rec.Code)
	}
}

func TestVNCSnapshotSection(t *testing.T) {
	v, sc := newTestVNC(t)
	h := &HAHub{vnc: v}

	got := h.vncSnapshot()
	if got == nil || got.On || got.Password != "" || got.Timeout != 15 || got.Port != 5900 {
		t.Fatalf("off snapshot = %+v", got)
	}
	_ = v.Set(true)
	expectCmd(t, sc, "start")
	got = h.vncSnapshot()
	if !got.On || got.Password != v.Password() || got.Username != vncUsername || got.ClosesAt == 0 {
		t.Fatalf("on snapshot = %+v", got)
	}

	t.Setenv("DASHBOARD_ASSISTANT_VNC", "")
	if (&HAHub{vnc: NewVNC()}).vncSnapshot() != nil {
		t.Fatal("a build without VNC must omit the section")
	}
}
