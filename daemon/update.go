package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Update-checker defaults. The repo and API base are overridable from the Nix
// update module (UPDATE_REPO / UPDATE_API_BASE) so a build can track a GitHub
// mirror or a self-hosted Gitea instead — both expose the same
// <apiBase>/repos/<repo>/releases list shape.
const (
	defaultUpdateRepo     = "ajfriesen/dashboard-assistant"
	defaultUpdateAPIBase  = "https://api.github.com"
	defaultUpdateInterval = time.Hour
	releaseSummaryMax     = 1000 // cap the retained release-notes payload

	// releaseListPage caps how many recent releases we pull. It bounds both the
	// stable-update search and the version-picker dropdown the daemon exposes.
	releaseListPage = 20
)

// errNoReleases means the source has no publishable release yet (a 404, or an
// empty/draft-only /releases list). Callers keep the previous known state rather
// than surfacing a spurious "update".
var errNoReleases = errors.New("no releases published yet")

// installedVersion is the release version baked into the image by the update
// module (environment.etc."dashboard-assistant/version"). Source/dirty builds have no
// file, so it reports "dev" — which never matches a release tag, i.e. "unknown".
func installedVersion() string {
	path := envOr("DASHBOARD_ASSISTANT_VERSION_FILE", "/etc/dashboard-assistant/version")
	if b, err := os.ReadFile(path); err == nil {
		if v := strings.TrimSpace(string(b)); v != "" {
			return v
		}
	}
	return "dev"
}

// Release is the subset of a GitHub/Gitea release we surface to HA. We fetch the
// /releases list and use Draft/Prerelease to classify each: drafts are dropped
// (no tag a rebuild could fetch), prereleases are kept but only offered through
// the version picker, never as an "update available" notification.
type Release struct {
	TagName    string `json:"tag_name"`
	Name       string `json:"name"`
	Body       string `json:"body"`
	HTMLURL    string `json:"html_url"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
}

// ReleaseInfo is one entry in the version picker: the raw tag to install, a
// display name, and whether it is a prerelease (so HA can mark it).
type ReleaseInfo struct {
	Tag        string `json:"tag"`
	Name       string `json:"name"`
	Prerelease bool   `json:"prerelease"`
}

// UpdateState is a snapshot of the update status, safe to read after State().
// Latest is normalised (leading "v" stripped) so it compares cleanly with the
// installed version, and only ever reflects a stable release (see State).
// Available is the full picker list (newest-first), stable and prerelease alike.
type UpdateState struct {
	Installed  string
	Latest     string
	URL        string
	Summary    string
	Title      string
	InProgress bool
	Available  []ReleaseInfo
}

// UpdateChecker polls the release source for the recent releases and holds the
// result for the HA hub to publish. It mirrors the Display/Activity observer
// pattern: on a change it fires the observer so the hub broadcasts fresh state.
type UpdateChecker struct {
	repo        string
	apiBase     string
	interval    time.Duration
	installable bool // whether HA gets an Install button (a privileged unit exists)
	client      *http.Client

	mu           sync.Mutex
	installed    string
	releases     []Release // recent releases, newest-first, drafts already dropped
	haveReleases bool
	installing   bool // an update is currently being applied

	observer func()
}

func NewUpdateChecker() *UpdateChecker {
	return &UpdateChecker{
		installed:   installedVersion(),
		repo:        envOr("UPDATE_REPO", defaultUpdateRepo),
		apiBase:     strings.TrimRight(envOr("UPDATE_API_BASE", defaultUpdateAPIBase), "/"),
		interval:    updateInterval(),
		installable: os.Getenv("UPDATE_INSTALLABLE") == "1",
		client:      &http.Client{Timeout: 15 * time.Second},
	}
}

// Installable reports whether this image can apply updates in place (a
// privileged dashboard-assistant-update@ unit is present). The bridge only offers HA an Install
// button when true.
func (u *UpdateChecker) Installable() bool { return u.installable }

// updateInterval reads UPDATE_CHECK_INTERVAL (a Go duration, e.g. "30m") or
// falls back to the hourly default.
func updateInterval() time.Duration {
	if s := os.Getenv("UPDATE_CHECK_INTERVAL"); s != "" {
		if d, err := time.ParseDuration(s); err == nil && d > 0 {
			return d
		}
	}
	return defaultUpdateInterval
}

// SetObserver registers a callback fired whenever the release set changes.
func (u *UpdateChecker) SetObserver(f func()) { u.observer = f }

// Run checks immediately, then on the interval, forever. Meant to run in its own
// goroutine. A failed check keeps the previous known value and retries next tick.
func (u *UpdateChecker) Run() {
	u.checkOnce()
	for range time.Tick(u.interval) {
		u.checkOnce()
	}
}

func (u *UpdateChecker) checkOnce() {
	rels, err := u.fetchReleases()
	if err != nil {
		log.Printf("update: check %s: %v", u.repo, err)
		return
	}
	u.mu.Lock()
	changed := !u.haveReleases || !sameTags(u.releases, rels)
	u.releases = rels
	u.haveReleases = true
	u.mu.Unlock()
	if changed && u.observer != nil {
		u.observer()
	}
}

// fetchReleases pulls the recent releases list and returns the publishable ones
// (drafts and tagless entries dropped) newest-first. GitHub and Gitea both
// return the list newest-first, so we preserve that order for the picker and for
// picking the newest stable.
func (u *UpdateChecker) fetchReleases() ([]Release, error) {
	var raw []Release
	url := fmt.Sprintf("%s/repos/%s/releases?per_page=%d", u.apiBase, u.repo, releaseListPage)
	if err := u.fetchJSON(url, &raw); err != nil {
		return nil, err
	}
	rels := make([]Release, 0, len(raw))
	for _, r := range raw {
		if r.Draft || strings.TrimSpace(r.TagName) == "" {
			continue
		}
		rels = append(rels, r)
	}
	if len(rels) == 0 {
		return nil, errNoReleases
	}
	return rels, nil
}

// fetchJSON GETs url and decodes the JSON body into dst. A 404 (no releases yet)
// maps to errNoReleases; other non-200s are reported by status.
func (u *UpdateChecker) fetchJSON(url string, dst any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	// GitHub rejects requests without a User-Agent; the Accept header pins the
	// v3 JSON media type (harmless to Gitea, which ignores it).
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "dashboard-assistant-os")

	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNoReleases
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("http %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(dst)
}

// sameTags reports whether two release lists carry the same tags in the same
// order — the cheap signature checkOnce uses to decide whether to broadcast.
func sameTags(a, b []Release) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].TagName != b[i].TagName {
			return false
		}
	}
	return true
}

// latestStableLocked returns the newest non-prerelease release. Caller holds mu.
func (u *UpdateChecker) latestStableLocked() (Release, bool) {
	for _, r := range u.releases {
		if !r.Prerelease {
			return r, true
		}
	}
	return Release{}, false
}

// installedIsPrereleaseLocked reports whether the running version matches a
// release the source marks as a prerelease. Caller holds mu. Used to keep the
// update entity quiet on a prerelease device: it must not be nagged toward a
// stable release that would look like a downgrade.
func (u *UpdateChecker) installedIsPrereleaseLocked() bool {
	for _, r := range u.releases {
		if normalizeVersion(r.TagName) == u.installed {
			return r.Prerelease
		}
	}
	return false
}

// State returns the current update status. Latest reflects only stable releases,
// and is pinned to Installed (i.e. "up to date") when the device is running a
// prerelease — so the "update available" notification fires only for a stable
// device with a newer stable release. The version picker (Available) still lists
// everything. Until the first successful check Latest mirrors Installed.
func (u *UpdateChecker) State() UpdateState {
	u.mu.Lock()
	defer u.mu.Unlock()

	st := UpdateState{Installed: u.installed, Latest: u.installed, InProgress: u.installing}
	if !u.haveReleases {
		return st
	}

	st.Available = u.availableLocked()

	// A prerelease device is treated as up to date on the notification entity.
	if u.installedIsPrereleaseLocked() {
		return st
	}
	if stable, ok := u.latestStableLocked(); ok {
		st.Latest = normalizeVersion(stable.TagName)
		st.URL = stable.HTMLURL
		st.Title = strings.TrimSpace(stable.Name)
		st.Summary = summarise(stable.Body)
	}
	return st
}

// availableLocked maps the fetched releases into picker entries. Caller holds mu.
func (u *UpdateChecker) availableLocked() []ReleaseInfo {
	out := make([]ReleaseInfo, 0, len(u.releases))
	for _, r := range u.releases {
		name := strings.TrimSpace(r.Name)
		if name == "" {
			name = strings.TrimSpace(r.TagName)
		}
		out = append(out, ReleaseInfo{
			Tag:        strings.TrimSpace(r.TagName),
			Name:       name,
			Prerelease: r.Prerelease,
		})
	}
	return out
}

// InstallTarget returns the raw stable release tag to update to (e.g. "v1.5.0"),
// and whether a stable update is actually available — false when nothing has
// been fetched, the device runs a prerelease, or the newest stable matches the
// installed version. This drives the update entity's Install button; the version
// picker installs an arbitrary tag through HasVersion + the install_version path.
func (u *UpdateChecker) InstallTarget() (string, bool) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if !u.haveReleases || u.installedIsPrereleaseLocked() {
		return "", false
	}
	stable, ok := u.latestStableLocked()
	if !ok || normalizeVersion(stable.TagName) == u.installed {
		return "", false
	}
	return strings.TrimSpace(stable.TagName), true
}

// HasVersion reports whether tag is one of the currently known releases. The
// install_version endpoint gates on it so a rebuild only ever targets a real,
// discovered release tag — never an arbitrary caller-supplied flake ref.
func (u *UpdateChecker) HasVersion(tag string) bool {
	tag = strings.TrimSpace(tag)
	if tag == "" {
		return false
	}
	u.mu.Lock()
	defer u.mu.Unlock()
	for _, r := range u.releases {
		if strings.TrimSpace(r.TagName) == tag {
			return true
		}
	}
	return false
}

// SetInstalling marks an update as in progress (or done), for the HA entity's
// in_progress flag.
func (u *UpdateChecker) SetInstalling(v bool) {
	u.mu.Lock()
	u.installing = v
	u.mu.Unlock()
}

// RefreshInstalled re-reads the baked-in version file. Called after a successful
// switch that didn't restart the daemon, so "installed" reflects the new system.
func (u *UpdateChecker) RefreshInstalled() {
	v := installedVersion()
	u.mu.Lock()
	u.installed = v
	u.mu.Unlock()
}

// normalizeVersion strips a leading "v" from a release tag ("v1.5.0" → "1.5.0")
// so tags compare cleanly against the plain installed version.
func normalizeVersion(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 1 && (s[0] == 'v' || s[0] == 'V') {
		return s[1:]
	}
	return s
}

// summarise trims the release body and caps it, keeping the state payload small
// (HA shows it as the release notes).
func summarise(body string) string {
	body = strings.TrimSpace(body)
	if len(body) > releaseSummaryMax {
		return body[:releaseSummaryMax] + "…"
	}
	return body
}
