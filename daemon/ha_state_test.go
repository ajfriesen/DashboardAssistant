package main

import (
	"encoding/json"
	"testing"
)

// The snapshot is the contract between this daemon and the Home Assistant
// integration, which lives in another repository and cannot be refactored along
// with a struct field. So the wire names are asserted on, not the Go ones.
//
// A rollback has to be reported here because it is the one update outcome the
// Install button cannot report: the switch succeeded, Home Assistant was told
// "done", and the generation only failed hours later on the next boot. Without
// these fields the device would simply appear to be running an older release
// than the one it was told to install, with nothing saying why.
func TestSnapshotReportsARollback(t *testing.T) {
	var s stateSnapshot
	s.Update.Installed = "1.4.0"
	s.Update.Latest = "1.4.0"
	s.Update.RolledBack = true
	s.Update.Rejected = "1.5.0"
	s.Update.RejectedGeneration = 2

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Update map[string]any `json:"update"`
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]any{
		"rolled_back":         true,
		"rejected_version":    "1.5.0",
		"rejected_generation": float64(2),
	} {
		if got.Update[key] != want {
			t.Errorf("update.%s = %v, want %v", key, got.Update[key], want)
		}
	}
}

// An ordinary device must not carry the rollback keys at all: the integration
// reads this payload ten times a minute, and "rolled_back": false on every
// device forever is noise that also invites a reader to treat its absence as
// unknown rather than as fine.
func TestSnapshotOmitsTheRollbackKeysWhenThereWasNone(t *testing.T) {
	b, err := json.Marshal(stateSnapshot{})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Update map[string]any `json:"update"`
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"rolled_back", "rejected_version", "rejected_generation"} {
		if _, ok := got.Update[key]; ok {
			t.Errorf("update.%s is present on a device that never rolled back", key)
		}
	}
}
