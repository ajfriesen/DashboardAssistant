package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/gorilla/websocket"
)

// cdpEndpoint is Chromium's DevTools (CDP) HTTP endpoint, opened on loopback by
// the kiosk when autoLogin/dev-debugging is on (see kiosk.nix — the same port the
// in-session zoom/theme/nav helpers use). The daemon shares the host network
// namespace, so unlike swaymsg it can reach this directly, with no in-session
// agent: it lists the page target, opens the debugger WebSocket, and asks
// Chromium to render the screenshot.
const cdpEndpoint = "http://127.0.0.1:9222"

// cdpPageWS returns the WebSocket debugger URL of the first browser "page" target.
func cdpPageWS(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, cdpEndpoint+"/json", nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("cdp list targets (is the debug port open?): %w", err)
	}
	defer resp.Body.Close()

	var targets []struct {
		Type string `json:"type"`
		WS   string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return "", fmt.Errorf("cdp decode targets: %w", err)
	}
	for _, t := range targets {
		if t.Type == "page" && t.WS != "" {
			return t.WS, nil
		}
	}
	return "", fmt.Errorf("cdp: no page target")
}

// captureScreenshot grabs a JPEG of the current kiosk web page over CDP
// (Page.captureScreenshot) and returns it base64-encoded. The HA API decodes it
// and caches the JPEG, which the integration's image entity fetches. It needs the
// loopback CDP port to be open (autoLogin with a staged token, or dev
// remote-debugging).
func captureScreenshot(ctx context.Context) (string, error) {
	wsURL, err := cdpPageWS(ctx)
	if err != nil {
		return "", err
	}
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return "", fmt.Errorf("cdp dial: %w", err)
	}
	defer conn.Close()
	conn.SetReadLimit(32 << 20) // screenshots are large; lift the default cap
	if dl, ok := ctx.Deadline(); ok {
		conn.SetWriteDeadline(dl)
		conn.SetReadDeadline(dl)
	}

	const req = `{"id":1,"method":"Page.captureScreenshot","params":{"format":"jpeg","quality":70}}`
	if err := conn.WriteMessage(websocket.TextMessage, []byte(req)); err != nil {
		return "", fmt.Errorf("cdp write: %w", err)
	}

	// Read until our command's reply (id 1); skip any interleaved CDP events.
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return "", fmt.Errorf("cdp read: %w", err)
		}
		var resp struct {
			ID     int `json:"id"`
			Result struct {
				Data string `json:"data"`
			} `json:"result"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &resp); err != nil || resp.ID != 1 {
			continue
		}
		if resp.Error != nil {
			return "", fmt.Errorf("cdp: %s", resp.Error.Message)
		}
		if resp.Result.Data == "" {
			return "", fmt.Errorf("cdp: empty screenshot")
		}
		return resp.Result.Data, nil
	}
}
