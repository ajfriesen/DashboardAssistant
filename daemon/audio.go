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

// Audio picks the device's audio output: PipeWire's default sink, which the
// Sendspin player and the kiosk's browser both play to. The daemon has no
// access to PipeWire (its socket also carries the microphone, and this is the
// process on the network), so the audio-output agent (modules/core/
// audio-output.nix) does the PipeWire side: it writes the sinks and the
// current default to a file, and makes the sink named on a FIFO the default.
// WirePlumber remembers that choice across reboots, so nothing is persisted
// here.
type Audio struct {
	mu       sync.Mutex
	file     string
	fifo     string
	observer func()
}

// AudioSink is one PipeWire sink: Name is its node.name, what PipeWire's
// metadata takes; Description is the label a person reads.
type AudioSink struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// AudioState is the snapshot's audio slice.
type AudioState struct {
	Current string      `json:"current"`
	Options []AudioSink `json:"options"`
}

// agentOutputs is the file the agent writes.
type agentOutputs struct {
	Default string      `json:"default"`
	Sinks   []AudioSink `json:"sinks"`
}

// NewAudio uses the agent's paths; both can be overridden for testing.
func NewAudio() *Audio {
	return &Audio{
		file: envOr("DASHBOARD_ASSISTANT_AUDIO_OUTPUTS", audioOutputsFile),
		fifo: envOr("DASHBOARD_ASSISTANT_AUDIO_FIFO", audioOutputFifo),
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
	out, err := a.read()
	if err != nil {
		return nil
	}
	return &AudioState{Current: out.Default, Options: out.Sinks}
}

func (a *Audio) read() (agentOutputs, error) {
	var out agentOutputs
	b, err := os.ReadFile(a.file)
	if err != nil {
		return out, err
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return out, err
	}
	if out.Sinks == nil {
		out.Sinks = []AudioSink{}
	}
	return out, nil
}

// Set makes the named sink the default. Only a sink the agent listed is
// accepted. The agent applies it asynchronously and republishes, so Set waits
// briefly for the file to show the new default, letting the caller answer
// with a snapshot that already has it.
func (a *Audio) Set(name string) error {
	out, err := a.read()
	if err != nil {
		return fmt.Errorf("audio outputs not available: %w", err)
	}
	if !slices.ContainsFunc(out.Sinks, func(s AudioSink) bool { return s.Name == name }) {
		return fmt.Errorf("no audio output named %q", name)
	}

	// O_NONBLOCK so opening a reader-less FIFO fails with ENXIO instead of blocking.
	f, err := os.OpenFile(a.fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("audio output agent not ready: %w", err)
	}
	_, werr := f.WriteString(name + "\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write audio output fifo: %w", werr)
	}

	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if out, err := a.read(); err == nil && out.Default == name {
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
