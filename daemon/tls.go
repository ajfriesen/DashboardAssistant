package main

// Self-signed TLS for the LAN Home Assistant API.
//
// What this is for: POST /api/ha/kiosk_login carries a Home Assistant
// long-lived access token with a ten-year lifetime, and the SSE stream carries
// the device's serial, MAC and hostname continuously. On a cleartext listener
// all of that is readable by anyone capturing packets on the network the panel
// sits on. That — passive capture — is the threat this closes.
//
// It does NOT authenticate the device on first contact. The integration pins
// this certificate's SHA-256 fingerprint the first time it connects and refuses
// anything else afterwards, so an attacker who arrives later is locked out; one
// who is already intercepting at the moment of pairing is not. That trade is
// deliberate and documented (REQUIREMENTS section 6).
//
// Self-signed rather than a real CA because there is nothing to issue against:
// the device is reached at a LAN IP that changes on DHCP renewal. For the same
// reason the integration pins the fingerprint instead of validating the chain —
// a fingerprint identifies the machine, not the address, so a new lease does not
// break the pin. The SANs below are therefore cosmetic for the integration, and
// exist so curl and the VM test behave sanely.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"time"
)

// certLifetime is deliberately long. Nothing renews this automatically, the
// device may sit on a wall for years, and an expiry would present as "cannot
// connect" with no explanation. Expiry buys nothing here anyway: the integration
// pins the fingerprint and never checks validity dates.
const certLifetime = 20 * 365 * 24 * time.Hour

// ensureTLSKeypair returns the device's certificate, generating and persisting
// one on first use. A file that exists but does not parse is treated as absent
// and regenerated: none of this daemon's atomic writes fsync before rename, so a
// power cut mid-write can leave a zero-length file, and a device that refuses to
// serve its API because of that would need a factory reset to recover.
func ensureTLSKeypair() (certPEM, keyPEM []byte, err error) {
	certPEM, certErr := os.ReadFile(tlsCertFile)
	keyPEM, keyErr := os.ReadFile(tlsKeyFile)
	if certErr == nil && keyErr == nil {
		if err := checkKeypair(certPEM, keyPEM); err == nil {
			return certPEM, keyPEM, nil
		}
		// Fall through and regenerate.
	}

	certPEM, keyPEM, err = generateSelfSigned()
	if err != nil {
		return nil, nil, fmt.Errorf("generate certificate: %w", err)
	}
	// The key is the one secret on this device that nothing else needs to read —
	// unlike the HA token, which the kiosk injects and so shares with the
	// `dashboard` group. 0600, not the 0640 used elsewhere.
	if err := writeAtomic(tlsKeyFile, keyPEM, 0o600); err != nil {
		return nil, nil, fmt.Errorf("write key: %w", err)
	}
	if err := writeAtomic(tlsCertFile, certPEM, 0o644); err != nil {
		return nil, nil, fmt.Errorf("write certificate: %w", err)
	}
	return certPEM, keyPEM, nil
}

// checkKeypair reports whether a stored pair is usable, so a truncated or
// corrupt file is regenerated rather than served.
func checkKeypair(certPEM, keyPEM []byte) error {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return fmt.Errorf("certificate is not PEM")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return fmt.Errorf("parse certificate: %w", err)
	}
	kb, _ := pem.Decode(keyPEM)
	if kb == nil {
		return fmt.Errorf("key is not PEM")
	}
	if _, err := x509.ParseECPrivateKey(kb.Bytes); err != nil {
		return fmt.Errorf("parse key: %w", err)
	}
	return nil
}

// generateSelfSigned mints an ECDSA P-256 certificate naming this device.
func generateSelfSigned() (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}

	// The node id is the identity Home Assistant keys the device on, so it is the
	// honest subject here. Hostname and current IP ride along as SANs so curl and
	// a browser behave; the integration ignores both and pins the fingerprint.
	host := hostname()
	names := []string{nodeID(), "localhost"}
	if host != "" && host != "localhost" {
		names = append(names, host)
	}
	ips := []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback}
	if ip := net.ParseIP(primaryIP()); ip != nil {
		ips = append(ips, ip)
	}

	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: nodeID(), Organization: []string{"Dashboard Assistant"}},
		NotBefore:             time.Now().Add(-1 * time.Hour), // tolerate a device whose clock has not synced yet
		NotAfter:              time.Now().Add(certLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              names,
		IPAddresses:           ips,
	}

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}
