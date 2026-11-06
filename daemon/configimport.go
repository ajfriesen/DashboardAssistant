package main

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// importConfig is the schema of the dashboard-assistant.yaml seed file, read
// from a USB stick or the ESP. It carries Wi-Fi and nothing else: the display
// has no way to ask for credentials, and everything past joining the network
// comes from Home Assistant when it pairs (the URL, the kiosk token, the
// pages), while the device makes its own API token. Any other key is ignored.
type importConfig struct {
	WiFi *struct {
		SSID string `yaml:"ssid"`
		PSK  string `yaml:"psk"`
	} `yaml:"wifi"`
}

// applyImport parses a seed file and joins the Wi-Fi it carries. It returns a
// short summary of what it applied, so the caller can decide whether to restart
// the kiosk: empty when the device was already on that network.
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
	return applied, nil
}
