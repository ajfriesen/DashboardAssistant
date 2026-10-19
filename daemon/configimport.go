package main

import (
	"fmt"
	"log"

	"gopkg.in/yaml.v3"
)

// importConfig is the schema of the dashboard-assistant.yaml bundle imported from a USB
// stick or the ESP. Every field is optional; only the ones present are applied.
type importConfig struct {
	HAURL string `yaml:"ha_url"`
	// KioskToken is the long-lived Home Assistant token the kiosk logs in with.
	// Named for the glossary (CONTEXT.md): a bare `token` next to `api_token`
	// does not say which of the two credentials it is.
	KioskToken string `yaml:"kiosk_token"`
	// LegacyToken is the key kiosk_token replaced, kept so seed files already
	// sitting on cards in the field keep provisioning a login. Read only when
	// kiosk_token is absent; see kioskToken.
	LegacyToken string `yaml:"token"`
	WiFi        *struct {
		SSID string `yaml:"ssid"`
		PSK  string `yaml:"psk"`
	} `yaml:"wifi"`
	// APIToken presets the device's Home Assistant API token, so a fleet can be
	// flashed with a known token instead of the per-device one generated on first
	// boot. Optional; omit to keep the generated token.
	APIToken string `yaml:"api_token"`
	Pages    []struct {
		Name string `yaml:"name"`
		URL  string `yaml:"url"`
	} `yaml:"pages"`
}

// kioskToken returns the kiosk token the bundle carries, preferring the current
// key over the deprecated one so a file mid-rename (carrying both) applies what
// its author last edited rather than whichever key the parser looked at first.
// Using the old key is logged, since the file is the only place to fix it and
// the journal is a headless device's one feedback channel.
func (c importConfig) kioskToken() string {
	if c.KioskToken != "" {
		return c.KioskToken
	}
	if c.LegacyToken != "" {
		log.Printf("import: seed file uses the deprecated key `token`; rename it to `kiosk_token`")
	}
	return c.LegacyToken
}

// applyImport parses a YAML bundle and applies whatever it carries: Wi-Fi first
// (so the box is online), then the kiosk token, then the HA URL (which also marks the
// device provisioned). It returns a short summary of what it applied, so the
// caller can decide whether to restart the kiosk.
//
// Note the asymmetry: only the Wi-Fi entry reflects an actual *change*, because
// NetworkManager has to be asked anyway to avoid duplicating a profile. The
// others report every key present in the bundle, changed or not. That is good
// enough because the boot importer does not re-POST an unchanged seed file at
// all (modules/core/configimport.nix gates on its content hash), so the
// redundant kiosk restart this could cause only arises on a repeated USB
// insert, where it is harmless.
func (s *server) applyImport(data []byte) ([]string, error) {
	var cfg importConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse yaml: %w", err)
	}

	var applied []string

	if cfg.WiFi != nil && cfg.WiFi.SSID != "" {
		if s.nm == nil {
			return applied, fmt.Errorf("wifi requested but NetworkManager is unavailable")
		}
		changed, err := s.nm.Provision(cfg.WiFi.SSID, cfg.WiFi.PSK)
		if err != nil {
			return applied, fmt.Errorf("wifi provision: %w", err)
		}
		// Only when it really changed: re-importing an edited seed file applies
		// the whole file, and a device already on this SSID needs no kiosk
		// restart on account of its Wi-Fi.
		if changed {
			applied = append(applied, "wifi:"+cfg.WiFi.SSID)
		}
	}

	if tok := cfg.kioskToken(); tok != "" {
		if err := writeToken(tok); err != nil {
			return applied, fmt.Errorf("write kiosk token: %w", err)
		}
		applied = append(applied, "kiosk_token")
	}

	if cfg.HAURL != "" {
		if err := writeHAURL(cfg.HAURL); err != nil {
			return applied, fmt.Errorf("write ha_url: %w", err)
		}
		if err := markProvisioned(); err != nil {
			return applied, fmt.Errorf("mark provisioned: %w", err)
		}
		applied = append(applied, "ha_url:"+cfg.HAURL)
	}

	if cfg.APIToken != "" {
		if err := writeAPIToken(cfg.APIToken); err != nil {
			return applied, fmt.Errorf("write api token: %w", err)
		}
		// Takes effect on the next daemon start (the API listener reads the token
		// at boot); note it so the operator knows to restart if changing it live.
		applied = append(applied, "api_token")
	}

	if cfg.Pages != nil {
		pages := make([]Page, 0, len(cfg.Pages))
		for _, p := range cfg.Pages {
			if p.URL != "" {
				pages = append(pages, Page{Name: p.Name, URL: p.URL})
			}
		}
		if s.pages != nil {
			if err := s.pages.SetList(pages); err != nil {
				return applied, fmt.Errorf("set pages: %w", err)
			}
		}
		applied = append(applied, fmt.Sprintf("pages:%d", len(pages)))
	}

	return applied, nil
}
