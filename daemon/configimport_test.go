package main

import (
	"os"
	"testing"
)

// A seed file carries Wi-Fi and nothing else. Home Assistant supplies the rest
// when it pairs: the URL, the kiosk token and the pages, and the device makes
// its own API token. A file that still has the keys earlier versions read is
// imported without error, and none of them changes anything.
func TestImportReadsOnlyWifi(t *testing.T) {
	tempState(t)
	pages := NewPages()
	before := pages.List()
	s := &server{pages: pages}

	applied, err := s.applyImport([]byte(`
ha_url: "http://198.51.100.7:8123"
kiosk_token: "eyJhbGci.kiosk"
token: "eyJhbGci.legacy"
api_token: "a-long-random-string"
pages:
  - name: "Seeded"
    url: "http://198.51.100.7:8123/lovelace/seeded"
`))
	if err != nil {
		t.Fatalf("applyImport: %v", err)
	}
	if len(applied) != 0 {
		t.Errorf("applied = %v, want nothing", applied)
	}
	for _, f := range []string{tokenFile, apiTokenFile, runtimeEnv, markerFile} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("%s exists after a seed without Wi-Fi, want it untouched", f)
		}
	}
	if got := pages.List(); len(got) != len(before) || got[0] != before[0] {
		t.Errorf("pages = %v, want them untouched (%v)", got, before)
	}
}
