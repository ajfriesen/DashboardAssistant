package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNormalizeVersion(t *testing.T) {
	cases := map[string]string{
		"v1.5.0":  "1.5.0",
		"V2.0":    "2.0",
		"1.5.0":   "1.5.0",
		"  v3.1 ": "3.1",
		"v":       "v", // too short to be a prefix; left alone
	}
	for in, want := range cases {
		if got := normalizeVersion(in); got != want {
			t.Errorf("normalizeVersion(%q) = %q, want %q", in, got, want)
		}
	}
}

// releasesServer serves a fixed /releases list, 404 for anything else.
func releasesServer(t *testing.T, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/owner/repo/releases" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
}

func newTestChecker(installed, apiBase string, client *http.Client) *UpdateChecker {
	return &UpdateChecker{
		installed: installed,
		repo:      "owner/repo",
		apiBase:   apiBase,
		interval:  time.Hour,
		client:    client,
	}
}

const sampleReleases = `[
	{"tag_name": "v1.6.0-rc1", "name": "1.6.0 RC1", "body": "RC", "prerelease": true,
	 "html_url": "https://example/releases/v1.6.0-rc1"},
	{"tag_name": "v1.5.0", "name": "Release 1.5.0", "body": "Notes",
	 "html_url": "https://example/releases/v1.5.0"},
	{"tag_name": "v1.4.0", "name": "Release 1.4.0", "body": "Old"}
]`

func TestCheckerFetchAndState(t *testing.T) {
	srv := releasesServer(t, sampleReleases)
	defer srv.Close()

	u := newTestChecker("1.4.0", srv.URL, srv.Client())

	// Before any check, latest mirrors installed (no spurious update).
	if st := u.State(); st.Latest != "1.4.0" || st.Available != nil {
		t.Fatalf("pre-check State = %+v, want mirror of installed, no available", st)
	}

	var fired int
	u.SetObserver(func() { fired++ })
	u.checkOnce()

	st := u.State()
	// Notification tracks the newest STABLE release, not the RC on top.
	if st.Installed != "1.4.0" || st.Latest != "1.5.0" {
		t.Fatalf("State = %+v, want installed 1.4.0 / latest 1.5.0", st)
	}
	if st.URL != "https://example/releases/v1.5.0" || st.Title != "Release 1.5.0" || st.Summary != "Notes" {
		t.Fatalf("State metadata = %+v, want the stable release's", st)
	}
	// The picker lists everything, newest-first, RC included and marked.
	if len(st.Available) != 3 {
		t.Fatalf("Available = %+v, want 3 entries", st.Available)
	}
	if st.Available[0].Tag != "v1.6.0-rc1" || !st.Available[0].Prerelease {
		t.Fatalf("Available[0] = %+v, want the marked RC", st.Available[0])
	}
	if st.Available[1].Tag != "v1.5.0" || st.Available[1].Prerelease {
		t.Fatalf("Available[1] = %+v, want stable v1.5.0", st.Available[1])
	}
	if fired != 1 {
		t.Fatalf("observer fired %d times, want 1", fired)
	}

	// A second identical check must not re-fire the observer.
	u.checkOnce()
	if fired != 1 {
		t.Fatalf("observer re-fired on unchanged release set: %d", fired)
	}
}

func TestStableOnlyNotificationOnPrereleaseDevice(t *testing.T) {
	srv := releasesServer(t, sampleReleases)
	defer srv.Close()

	// The device is running the RC itself; it must not be nagged toward the older
	// stable release, so the notification entity reports "up to date".
	u := newTestChecker("1.6.0-rc1", srv.URL, srv.Client())
	u.checkOnce()

	st := u.State()
	if st.Latest != st.Installed {
		t.Fatalf("prerelease device: Latest = %q, want up to date (%q)", st.Latest, st.Installed)
	}
	if st.URL != "" || st.Title != "" {
		t.Fatalf("prerelease device advertised an update: %+v", st)
	}
	// The picker is still fully populated so the user can move off the RC.
	if len(st.Available) != 3 {
		t.Fatalf("Available = %+v, want 3 entries", st.Available)
	}
	if _, ok := u.InstallTarget(); ok {
		t.Fatalf("InstallTarget on a prerelease device should be empty")
	}
}

func TestInstallTarget(t *testing.T) {
	u := &UpdateChecker{installed: "1.4.0"}

	// No releases fetched yet → nothing to install.
	if ref, ok := u.InstallTarget(); ok {
		t.Fatalf("InstallTarget before check = (%q, true), want no target", ref)
	}

	u.releases = []Release{
		{TagName: "v1.6.0-rc1", Prerelease: true},
		{TagName: "v1.5.0"},
		{TagName: "v1.4.0"},
	}
	u.haveReleases = true

	// Newest STABLE (not the RC) is the target for a stable device.
	if ref, ok := u.InstallTarget(); !ok || ref != "v1.5.0" {
		t.Fatalf("InstallTarget = (%q, %v), want (\"v1.5.0\", true)", ref, ok)
	}

	// Already on the newest stable → nothing to install.
	u.installed = "1.5.0"
	if ref, ok := u.InstallTarget(); ok {
		t.Fatalf("InstallTarget when up to date = (%q, true), want no target", ref)
	}
}

func TestHasVersion(t *testing.T) {
	u := &UpdateChecker{
		haveReleases: true,
		releases: []Release{
			{TagName: "v1.6.0-rc1", Prerelease: true},
			{TagName: "v1.5.0"},
		},
	}
	for tag, want := range map[string]bool{
		"v1.6.0-rc1": true,
		"v1.5.0":     true,
		"v9.9.9":     false, // never published — must be rejected
		"":           false,
	} {
		if got := u.HasVersion(tag); got != want {
			t.Errorf("HasVersion(%q) = %v, want %v", tag, got, want)
		}
	}
}

func TestFetchDropsDrafts(t *testing.T) {
	srv := releasesServer(t, `[
		{"tag_name": "v2.0.0-draft", "draft": true},
		{"tag_name": "", "name": "tagless"},
		{"tag_name": "v1.5.0", "name": "Release 1.5.0"}
	]`)
	defer srv.Close()

	u := newTestChecker("1.4.0", srv.URL, srv.Client())
	u.checkOnce()

	st := u.State()
	if len(st.Available) != 1 || st.Available[0].Tag != "v1.5.0" {
		t.Fatalf("Available = %+v, want only the published v1.5.0", st.Available)
	}
	if st.Latest != "1.5.0" {
		t.Fatalf("Latest = %q, want 1.5.0 (draft/tagless skipped)", st.Latest)
	}
}

func TestCheckerNoReleases(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r) // GitHub/Gitea return 404 when there are no releases
	}))
	defer srv.Close()

	u := newTestChecker("1.4.0", srv.URL, srv.Client())
	u.SetObserver(func() { t.Fatal("observer fired on a failed check") })
	u.checkOnce()

	if st := u.State(); st.Latest != "1.4.0" || st.Available != nil {
		t.Fatalf("after 404, State = %+v, want mirror of installed, no available", st)
	}
}
