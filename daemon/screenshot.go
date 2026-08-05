package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"syscall"
	"time"
)

// Whole-screen screenshots are taken by an in-session agent running grim (which
// speaks wlroots' screencopy protocol), so the frame is the entire Wayland
// output — the waybar bar, the on-screen keyboard and any splash included — not
// just the Chromium web view (the old CDP Page.captureScreenshot only ever saw
// the page). The daemon runs outside the Sway session and can't reach the
// Wayland socket, so it uses the same handshake as the other in-session agents:
// it pokes a request FIFO, the agent grabs a frame to screenshotFile via an
// atomic rename, and the daemon reads that file back.
//
// One capture at a time: the freshness check keys off the file's mtime, so
// overlapping requests would race over which frame each observes.
var shotCaptureMu sync.Mutex

// captureScreenshot triggers a whole-screen grab and returns the JPEG bytes. It
// needs the kiosk session (and its grim agent) to be up; if not, the FIFO poke
// fails or the wait times out against ctx.
func captureScreenshot(ctx context.Context) ([]byte, error) {
	shotCaptureMu.Lock()
	defer shotCaptureMu.Unlock()

	// Any frame the agent writes after this instant is ours; a screenshotFile
	// left by an earlier capture has an older mtime and is skipped.
	reqAt := time.Now()

	if err := pokeScreenshotAgent(); err != nil {
		return nil, err
	}

	file := envOr("DASHBOARD_ASSISTANT_SCREENSHOT_FILE", screenshotFile)
	for {
		if fi, err := os.Stat(file); err == nil && fi.ModTime().After(reqAt) {
			img, err := os.ReadFile(file)
			if err != nil {
				return nil, fmt.Errorf("read screenshot: %w", err)
			}
			if len(img) == 0 {
				return nil, fmt.Errorf("screenshot: empty frame")
			}
			return img, nil
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("screenshot timed out (is the kiosk session up?): %w", ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// pokeScreenshotAgent asks the in-session grim agent for one frame. O_NONBLOCK so
// opening a reader-less FIFO (session down) fails with ENXIO instead of blocking,
// mirroring the display/nav/zoom writers.
func pokeScreenshotAgent() error {
	fifo := envOr("DASHBOARD_ASSISTANT_SCREENSHOT_FIFO", screenshotFifo)
	f, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("screenshot session not ready: %w", err)
	}
	_, werr := f.WriteString("shot\n")
	f.Close()
	if werr != nil {
		return fmt.Errorf("write screenshot fifo: %w", werr)
	}
	return nil
}
