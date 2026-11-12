package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// VNC lets someone see and drive the kiosk from another computer, for the jobs
// a touchscreen is bad at, like signing in to Google Calendar. It is off unless
// Home Assistant switches it on, and always off after a boot or a daemon
// restart.
//
// wayvnc has to run inside the Sway session, which the daemon cannot reach, so
// it uses the same handshake as the other in-session agents: the daemon writes
// this session's wayvnc config to vncConfigFile and then "start" or "stop" to a
// FIFO, and the agent in modules/core/vnc.nix runs or kills wayvnc.
//
// Security comes from three things:
//   - A random password made each time VNC goes on and shown only in Home
//     Assistant. Turning VNC off throws it away, so it stops working.
//   - Encrypted security types only (RSA-AES and VeNCrypt/TLS). The config
//     never sets relax_encryption or allow_broken_crypto, so a client that
//     cannot encrypt cannot connect.
//   - The auto-close timer, which ends a session someone forgot about.
type VNC struct {
	mu        sync.Mutex
	available bool
	port      int
	fifo      string
	on        bool
	password  string
	startedAt time.Time
	timeout   int // minutes; 0 = never close by itself
	session   int // bumped per session, so a stale timer can tell it is stale
	timer     *time.Timer
	observer  func()

	// minute is the auto-close unit. Always time.Minute outside tests.
	minute time.Duration
}

const (
	// The username clients send with RSA-AES and VeNCrypt Plain. Fixed and
	// public: the password is the secret.
	vncUsername = "dashboard"
	// Minutes before VNC closes by itself on a device that never set its own.
	vncDefaultTimeout = 15
	// Timeout ceiling in minutes, mirrored by the HA number entity. 0 = never.
	vncMaxTimeout = 240
	// No 0/O, 1/l/I: the password gets typed in by hand from the HA screen.
	vncPasswordAlphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	vncPasswordLength   = 12 // ~70 bits; the server is only up for one session anyway
)

type vncPrefs struct {
	Timeout int `json:"timeout"`
}

// NewVNC reads whether this build ships VNC (set by modules/core/vnc.nix) and
// the persisted timeout. The FIFO path can be overridden for tests.
func NewVNC() *VNC {
	port, err := strconv.Atoi(os.Getenv("DASHBOARD_ASSISTANT_VNC_PORT"))
	if err != nil || port <= 0 {
		port = 5900
	}
	return &VNC{
		available: os.Getenv("DASHBOARD_ASSISTANT_VNC") == "1",
		port:      port,
		fifo:      envOr("DASHBOARD_ASSISTANT_VNC_FIFO", vncFifo),
		timeout:   loadVNCPrefs().Timeout,
		minute:    time.Minute,
	}
}

// SetObserver registers a callback fired (outside the lock) after any change.
func (v *VNC) SetObserver(f func()) {
	v.mu.Lock()
	v.observer = f
	v.mu.Unlock()
}

func (v *VNC) Available() bool { return v.available }
func (v *VNC) Port() int       { return v.port }

func (v *VNC) On() bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.on
}

// Password is this session's password, or "" while VNC is off.
func (v *VNC) Password() string {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.password
}

func (v *VNC) Timeout() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.timeout
}

// ClosesAt is when the auto-close fires, or the zero time when it won't (VNC
// off, or the timeout is 0).
func (v *VNC) ClosesAt() time.Time {
	v.mu.Lock()
	defer v.mu.Unlock()
	if !v.on || v.timeout == 0 {
		return time.Time{}
	}
	return v.startedAt.Add(time.Duration(v.timeout) * v.minute)
}

// Set switches VNC on or off. Switching on while on keeps the current session
// and its password.
func (v *VNC) Set(on bool) error {
	if !on {
		v.stop()
		return nil
	}
	if !v.available {
		return fmt.Errorf("vnc not available on this device")
	}

	v.mu.Lock()
	if v.on {
		v.mu.Unlock()
		return nil
	}
	if err := ensureVNCKeys(); err != nil {
		v.mu.Unlock()
		return fmt.Errorf("vnc keys: %w", err)
	}
	password := vncPassword()
	if err := writeAtomic(vncConfigFile, []byte(v.config(password)), 0o640); err != nil {
		v.mu.Unlock()
		return fmt.Errorf("write wayvnc config: %w", err)
	}
	if err := v.writeCmd("start"); err != nil {
		_ = os.Remove(vncConfigFile)
		v.mu.Unlock()
		return err
	}
	v.on = true
	v.password = password
	v.startedAt = time.Now()
	v.session++
	v.schedule()
	obs := v.observer
	v.mu.Unlock()

	if obs != nil {
		obs()
	}
	return nil
}

// stop ends the session. It can't fail: with no kiosk session to tell, there
// is no wayvnc running either, so a FIFO that nobody reads is not an error.
func (v *VNC) stop() {
	v.mu.Lock()
	_ = v.writeCmd("stop")
	changed := v.clear()
	obs := v.observer
	v.mu.Unlock()
	if changed && obs != nil {
		obs()
	}
}

// clear forgets the session: password, timer and the config holding the
// password. Caller holds the lock. Reports whether VNC was on.
func (v *VNC) clear() bool {
	was := v.on
	v.on = false
	v.password = ""
	v.session++
	if v.timer != nil {
		v.timer.Stop()
		v.timer = nil
	}
	if err := os.Remove(vncConfigFile); err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "vnc: remove %s: %v\n", vncConfigFile, err)
	}
	return was
}

// SetTimeout sets the auto-close in minutes (0 = never), clamped to range. A
// running session's countdown still starts from when it went on, so a timeout
// shorter than it has already run closes it now.
func (v *VNC) SetTimeout(minutes int) {
	minutes = max(0, min(minutes, vncMaxTimeout))
	v.mu.Lock()
	v.timeout = minutes
	v.save()
	if v.on {
		v.schedule()
	}
	obs := v.observer
	v.mu.Unlock()
	if obs != nil {
		obs()
	}
}

// schedule (re)arms the auto-close for the current session. Caller holds the
// lock. The callback checks the session number, because Timer.Stop cannot
// recall a callback that is already running.
func (v *VNC) schedule() {
	if v.timer != nil {
		v.timer.Stop()
		v.timer = nil
	}
	if v.timeout == 0 {
		return
	}
	session := v.session
	left := time.Until(v.startedAt.Add(time.Duration(v.timeout) * v.minute))
	v.timer = time.AfterFunc(max(left, 0), func() {
		v.mu.Lock()
		stale := v.session != session || !v.on
		v.mu.Unlock()
		if !stale {
			fmt.Fprintln(os.Stderr, "vnc: timeout reached, closing")
			v.stop()
		}
	})
}

// Reset runs at daemon start. A daemon that restarted has no timer for a
// wayvnc its predecessor started, so it stops whatever might be running and
// removes the old password. Best-effort: at boot the session isn't up yet,
// which just means nothing is running.
func (v *VNC) Reset() {
	v.mu.Lock()
	_ = v.writeCmd("stop")
	v.clear()
	v.mu.Unlock()
}

// ReportOff records that wayvnc is gone without driving the FIFO: the session
// restarted, or wayvnc exited on its own.
func (v *VNC) ReportOff() {
	v.mu.Lock()
	changed := v.clear()
	obs := v.observer
	v.mu.Unlock()
	if changed && obs != nil {
		obs()
	}
}

// config renders this session's wayvnc config (see wayvnc(1)). Binding to all
// addresses is fine: the firewall opens the port to the LAN only and nothing
// listens while VNC is off.
func (v *VNC) config(password string) string {
	return fmt.Sprintf(`address=0.0.0.0
port=%d
enable_auth=true
username=%s
password=%s
rsa_private_key_file=%s
private_key_file=%s
certificate_file=%s
`, v.port, vncUsername, password, vncRSAKeyFile, vncTLSKeyFile, vncTLSCertFile)
}

// writeCmd sends one command line to the in-session agent. Caller holds the
// lock. O_NONBLOCK so a FIFO with no reader fails with ENXIO instead of
// blocking.
func (v *VNC) writeCmd(line string) error {
	f, err := os.OpenFile(v.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("vnc session not ready: %w", err)
	}
	_, werr := f.WriteString(line + "\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write vnc fifo: %w", werr)
	}
	return nil
}

// save persists the timeout; caller holds the lock. Best-effort, like the
// screen saver prefs.
func (v *VNC) save() {
	b, _ := json.Marshal(vncPrefs{Timeout: v.timeout})
	if err := writeAtomic(vncFile, append(b, '\n'), 0o664); err != nil {
		fmt.Fprintf(os.Stderr, "vnc: save %s: %v\n", vncFile, err)
	}
}

// loadVNCPrefs reads the persisted timeout, falling back to the default on a
// missing or bad file. A stored 0 is kept: that is the user turning it off.
func loadVNCPrefs() vncPrefs {
	p := vncPrefs{Timeout: vncDefaultTimeout}
	if b, err := os.ReadFile(vncFile); err == nil {
		_ = json.Unmarshal(b, &p)
	}
	p.Timeout = max(0, min(p.Timeout, vncMaxTimeout))
	return p
}

// vncPassword returns a fresh random password from vncPasswordAlphabet.
func vncPassword() string {
	n := big.NewInt(int64(len(vncPasswordAlphabet)))
	b := make([]byte, vncPasswordLength)
	for i := range b {
		k, err := rand.Int(rand.Reader, n)
		if err != nil {
			panic(fmt.Sprintf("vnc: crypto/rand: %v", err)) // the kernel's CSPRNG does not fail
		}
		b[i] = vncPasswordAlphabet[k.Int64()]
	}
	return string(b)
}

// ensureVNCKeys creates wayvnc's keys the first time VNC goes on and keeps them
// afterwards. Files that don't parse are made again, as in ensureTLSKeypair.
//
// The keys are 0640, not the 0600 of the API's TLS key, because wayvnc runs as
// the kiosk user, which reads them through the shared group. That puts them at
// the same trust level as the kiosk token the kiosk user already holds.
func ensureVNCKeys() error {
	if b, err := os.ReadFile(vncRSAKeyFile); err != nil || parseRSAKey(b) != nil {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return err
		}
		pemKey := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
		if err := writeAtomic(vncRSAKeyFile, pemKey, 0o640); err != nil {
			return err
		}
	}
	if checkKeypairFiles(vncTLSCertFile, vncTLSKeyFile) != nil {
		certPEM, keyPEM, err := generateSelfSigned()
		if err != nil {
			return err
		}
		if err := writeAtomic(vncTLSKeyFile, keyPEM, 0o640); err != nil {
			return err
		}
		if err := writeAtomic(vncTLSCertFile, certPEM, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// parseRSAKey checks that b is a PKCS#1 PEM RSA key, the format wayvnc reads.
func parseRSAKey(b []byte) error {
	block, _ := pem.Decode(b)
	if block == nil || block.Type != "RSA PRIVATE KEY" {
		return fmt.Errorf("not a PKCS#1 PEM key")
	}
	_, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	return err
}

// checkKeypairFiles is checkKeypair for a pair on disk.
func checkKeypairFiles(certFile, keyFile string) error {
	certPEM, err := os.ReadFile(certFile)
	if err != nil {
		return err
	}
	keyPEM, err := os.ReadFile(keyFile)
	if err != nil {
		return err
	}
	return checkKeypair(certPEM, keyPEM)
}
