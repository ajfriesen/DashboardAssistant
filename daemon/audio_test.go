package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// newTestAudio points Audio at a temp outputs file (as the audio-output agent
// writes it) and a temp FIFO held open read-write, like the agent does, and
// returns a reader for the sink names it is sent.
func newTestAudio(t *testing.T, outputs string) (*Audio, *bufio.Scanner) {
	t.Helper()
	dir := t.TempDir()
	fifo := filepath.Join(dir, "audio-output.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })

	file := filepath.Join(dir, "outputs.json")
	if outputs != "" {
		if err := os.WriteFile(file, []byte(outputs), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DASHBOARD_ASSISTANT_AUDIO_OUTPUTS", file)
	t.Setenv("DASHBOARD_ASSISTANT_AUDIO_FIFO", fifo)
	return NewAudio(), bufio.NewScanner(f)
}

const twoSinks = `{"default":"alsa_output.hdmi","sinks":[
  {"name":"alsa_output.hdmi","description":"Built-in Audio HDMI"},
  {"name":"alsa_output.usb","description":"USB Audio"}]}`

func TestAudioReadsTheAgentsOutputs(t *testing.T) {
	a, _ := newTestAudio(t, twoSinks)
	s := a.State()
	if s == nil {
		t.Fatal("no audio state although the agent published outputs")
	}
	if s.Current != "alsa_output.hdmi" || len(s.Options) != 2 || s.Options[1].Description != "USB Audio" {
		t.Fatalf("state = %+v", s)
	}
}

// No file means no audio stack (or no agent yet): the snapshot leaves the
// section out, so the integration creates no select.
func TestAudioAbsentWithoutAgent(t *testing.T) {
	a, _ := newTestAudio(t, "")
	if s := a.State(); s != nil {
		t.Fatalf("state = %+v, want nil", s)
	}
}

func TestAudioSetSendsTheSinkToTheAgent(t *testing.T) {
	a, sc := newTestAudio(t, twoSinks)
	fired := 0
	a.SetObserver(func() { fired++ })
	if err := a.Set("alsa_output.usb"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if !sc.Scan() || sc.Text() != "alsa_output.usb" {
		t.Fatalf("agent got %q", sc.Text())
	}
	if fired != 1 {
		t.Fatalf("observer fired %d times, want 1", fired)
	}
}

// Only a sink the agent listed can be picked: the name goes into PipeWire's
// metadata, and an unknown one would leave the device with no default.
func TestAudioSetRefusesUnknownSink(t *testing.T) {
	a, _ := newTestAudio(t, twoSinks)
	if err := a.Set("alsa_output.gone"); err == nil {
		t.Fatal("Set accepted a sink the agent never listed")
	}
}

func TestAudioStateMarshalsForTheSnapshot(t *testing.T) {
	a, _ := newTestAudio(t, twoSinks)
	b, err := json.Marshal(a.State())
	if err != nil {
		t.Fatal(err)
	}
	want := `{"current":"alsa_output.hdmi","options":[{"name":"alsa_output.hdmi","description":"Built-in Audio HDMI"},{"name":"alsa_output.usb","description":"USB Audio"}]}`
	if string(b) != want {
		t.Fatalf("json = %s\nwant   %s", b, want)
	}
}
