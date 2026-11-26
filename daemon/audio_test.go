package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// newTestAudio points Audio at a temp devices file (as the audio agent writes
// it) and a temp FIFO held open read-write, like the agent does, and returns a
// reader for the lines it is sent.
func newTestAudio(t *testing.T, devices string) (*Audio, *bufio.Scanner) {
	t.Helper()
	dir := t.TempDir()
	fifo := filepath.Join(dir, "audio.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })

	file := filepath.Join(dir, "devices.json")
	if devices != "" {
		if err := os.WriteFile(file, []byte(devices), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DASHBOARD_ASSISTANT_AUDIO_DEVICES", file)
	t.Setenv("DASHBOARD_ASSISTANT_AUDIO_FIFO", fifo)
	return NewAudio(), bufio.NewScanner(f)
}

const twoOfEach = `{
  "output":{"current":"alsa_output.hdmi","options":[
    {"name":"alsa_output.hdmi","description":"Built-in Audio HDMI"},
    {"name":"alsa_output.usb","description":"USB Audio"}]},
  "input":{"current":"alsa_input.usb","options":[
    {"name":"alsa_input.usb","description":"USB Audio"},
    {"name":"alsa_input.mic","description":"USB Microphone"}]}}`

func TestAudioReadsTheAgentsDevices(t *testing.T) {
	a, _ := newTestAudio(t, twoOfEach)
	s := a.State()
	if s == nil {
		t.Fatal("no audio state although the agent published devices")
	}
	if s.Output.Current != "alsa_output.hdmi" || len(s.Output.Options) != 2 || s.Output.Options[1].Description != "USB Audio" {
		t.Fatalf("output = %+v", s.Output)
	}
	if s.Input.Current != "alsa_input.usb" || len(s.Input.Options) != 2 || s.Input.Options[1].Name != "alsa_input.mic" {
		t.Fatalf("input = %+v", s.Input)
	}
}

// No microphone is the common case: the input side is there, just empty, so
// the integration can still create the select and fill it once one is plugged in.
func TestAudioWithoutMicrophoneHasAnEmptyInput(t *testing.T) {
	a, _ := newTestAudio(t, `{"output":{"current":"auto_null","options":[{"name":"auto_null","description":"Dummy Output"}]},"input":{"current":"","options":[]}}`)
	b, err := json.Marshal(a.State().Input)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"current":"","options":[]}` {
		t.Fatalf("input json = %s", b)
	}
}

// No file means no audio stack (or no agent yet): the snapshot leaves the
// section out, so the integration creates no selects.
func TestAudioAbsentWithoutAgent(t *testing.T) {
	a, _ := newTestAudio(t, "")
	if s := a.State(); s != nil {
		t.Fatalf("state = %+v, want nil", s)
	}
}

func TestAudioSetSendsTheChoiceToTheAgent(t *testing.T) {
	for _, tc := range []struct{ kind, name, line string }{
		{"output", "alsa_output.usb", "output alsa_output.usb"},
		{"input", "alsa_input.mic", "input alsa_input.mic"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			a, sc := newTestAudio(t, twoOfEach)
			fired := 0
			a.SetObserver(func() { fired++ })
			if err := a.Set(tc.kind, tc.name); err != nil {
				t.Fatalf("Set: %v", err)
			}
			if !sc.Scan() || sc.Text() != tc.line {
				t.Fatalf("agent got %q, want %q", sc.Text(), tc.line)
			}
			if fired != 1 {
				t.Fatalf("observer fired %d times, want 1", fired)
			}
		})
	}
}

// Only a device the agent listed, on the side it was listed for, can be
// picked: the name goes into PipeWire's metadata, and an unknown one would
// leave the device with no default.
func TestAudioSetRefusesWhatTheAgentDidNotList(t *testing.T) {
	a, _ := newTestAudio(t, twoOfEach)
	for _, tc := range []struct{ kind, name string }{
		{"output", "alsa_output.gone"},
		{"output", "alsa_input.mic"}, // a source is not an output
		{"input", "alsa_output.hdmi"},
		{"speaker", "alsa_output.hdmi"},
	} {
		if err := a.Set(tc.kind, tc.name); err == nil {
			t.Errorf("Set(%q, %q) was accepted", tc.kind, tc.name)
		}
	}
}

func TestAudioStateMarshalsForTheSnapshot(t *testing.T) {
	a, _ := newTestAudio(t, twoOfEach)
	b, err := json.Marshal(a.State())
	if err != nil {
		t.Fatal(err)
	}
	want := `{"output":{"current":"alsa_output.hdmi","options":[{"name":"alsa_output.hdmi","description":"Built-in Audio HDMI"},{"name":"alsa_output.usb","description":"USB Audio"}]},` +
		`"input":{"current":"alsa_input.usb","options":[{"name":"alsa_input.usb","description":"USB Audio"},{"name":"alsa_input.mic","description":"USB Microphone"}]}}`
	if string(b) != want {
		t.Fatalf("json = %s\nwant   %s", b, want)
	}
}
