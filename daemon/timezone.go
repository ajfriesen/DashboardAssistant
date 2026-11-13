package main

import (
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/godbus/dbus/v5"
)

// The device's timezone is Home Assistant's: the integration pushes its own zone
// (hass.config.time_zone) after pairing, and the daemon hands it to timedated.
// The clock screen saver and any dashboard card that formats a time in the
// browser read the system zone, so without this every device showed UTC.
//
// Nothing is kept here. timedated writes /etc/localtime, which is the record and
// survives a reboot; a device that has never been told stays on UTC.

// applyTimezone sets the system zone. A variable so tests need no system bus.
var applyTimezone = timedatedSetTimezone

// validTimezone reports whether name is a zone in the tz database. timedated
// checks too, but a bad name is the caller's mistake (400), not a failure on the
// device (500), so it is caught before the bus call. "Local" is Go's name for
// whatever the system has now, and an absolute path is a file, not a zone.
func validTimezone(name string) bool {
	if name == "" || name == "Local" || strings.HasPrefix(name, "/") || strings.Contains(name, "..") {
		return false
	}
	_, err := time.LoadLocation(name)
	return err == nil
}

// timedatedSetTimezone calls org.freedesktop.timedate1.SetTimezone. The daemon is
// allowed exactly this action by the polkit rule in modules/core/daemon.nix;
// interactive=false, because there is nobody to ask.
func timedatedSetTimezone(name string) error {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return err
	}
	defer conn.Close()
	obj := conn.Object("org.freedesktop.timedate1", "/org/freedesktop/timedate1")
	if call := obj.Call("org.freedesktop.timedate1.SetTimezone", 0, name, false); call.Err != nil {
		return fmt.Errorf("set timezone %s: %w", name, call.Err)
	}
	return nil
}

// handleTimezone sets the system zone ({"timezone": "Europe/Berlin"}).
func (h *HAHub) handleTimezone(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Timezone string `json:"timezone"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validTimezone(req.Timezone) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "timezone must be a tz database name, such as Europe/Berlin"})
		return
	}
	if err := applyTimezone(req.Timezone); err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"timezone": req.Timezone})
}
