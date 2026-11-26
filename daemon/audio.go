package main

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"sync"
	"syscall"
	"time"
)

// Audio picks the device's audio output and input: PipeWire's default sink
// (which the Sendspin player and the kiosk's browser play to) and default
// source (which a voice assistant records from). The daemon has no access to
// PipeWire (its socket also carries the microphone, and this is the process on
// the network), so the audio agent (modules/core/audio.nix) does the PipeWire
// side: it writes the sinks, the sources and the current defaults to a file,
// and makes the device named on a FIFO the default. WirePlumber remembers
// those choices across reboots, so nothing is persisted here.
type Audio struct {
	mu       sync.Mutex
	file     string
	fifo     string
	observer func()
}

// AudioDevice is one PipeWire sink or source: Name is its node.name, what
// PipeWire's metadata takes; Description is the label a person reads.
type AudioDevice struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// AudioChoice is one side, output or input: the devices and the default.
// Current is "" while there is none, e.g. no microphone attached.
type AudioChoice struct {
	Current string        `json:"current"`
	Options []AudioDevice `json:"options"`
}

// AudioState is the snapshot's audio slice, and also exactly what the agent
// writes.
type AudioState struct {
	Output AudioChoice `json:"output"`
	Input  AudioChoice `json:"input"`
}

// side returns the output or input half, or nil for anything else.
func (s *AudioState) side(kind string) *AudioChoice {
	switch kind {
	case "output":
		return &s.Output
	case "input":
		return &s.Input
	}
	return nil
}

// NewAudio uses the agent's paths; both can be overridden for testing.
func NewAudio() *Audio {
	return &Audio{
		file: envOr("DASHBOARD_ASSISTANT_AUDIO_DEVICES", audioDevicesFile),
		fifo: envOr("DASHBOARD_ASSISTANT_AUDIO_FIFO", audioFifo),
	}
}

// SetObserver registers a callback fired after a change, so the HA hub can
// broadcast it.
func (a *Audio) SetObserver(f func()) {
	a.mu.Lock()
	a.observer = f
	a.mu.Unlock()
}

// State reads what the agent last published, or nil when there is nothing to
// read: a build without the audio stack, or an agent that has not written yet.
func (a *Audio) State() *AudioState {
	s, err := a.read()
	if err != nil {
		return nil
	}
	return &s
}

func (a *Audio) read() (AudioState, error) {
	var s AudioState
	b, err := os.ReadFile(a.file)
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return s, err
	}
	for _, c := range []*AudioChoice{&s.Output, &s.Input} {
		if c.Options == nil {
			c.Options = []AudioDevice{}
		}
	}
	return s, nil
}

// Has reports whether the agent listed a device of that name on that side
// ("output" or "input").
func (a *Audio) Has(kind, name string) bool {
	s, err := a.read()
	if err != nil {
		return false
	}
	c := s.side(kind)
	return c != nil && slices.ContainsFunc(c.Options, func(d AudioDevice) bool { return d.Name == name })
}

// Set makes the named device the default output or input. Only a device the
// agent listed on that side is accepted. The agent applies it asynchronously
// and republishes, so Set waits briefly for the file to show the new default,
// letting the caller answer with a snapshot that already has it.
func (a *Audio) Set(kind, name string) error {
	if _, err := a.read(); err != nil {
		return fmt.Errorf("audio devices not available: %w", err)
	}
	if !a.Has(kind, name) {
		return fmt.Errorf("no audio %s named %q", kind, name)
	}

	// O_NONBLOCK so opening a reader-less FIFO fails with ENXIO instead of blocking.
	f, err := os.OpenFile(a.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("audio agent not ready: %w", err)
	}
	_, werr := f.WriteString(kind + " " + name + "\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write audio fifo: %w", werr)
	}

	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if s, err := a.read(); err == nil && s.side(kind).Current == name {
			break
		}
	}

	a.mu.Lock()
	obs := a.observer
	a.mu.Unlock()
	if obs != nil {
		obs()
	}
	return nil
}
