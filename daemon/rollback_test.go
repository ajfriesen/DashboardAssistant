package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func rollbackRequest(h *HAHub, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/ha/rollback", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.routes().ServeHTTP(rec, req)
	return rec
}

// Rolling back reboots the device into another system, so it runs only for the
// Home Assistant that holds the device token (docs/adr/0014).
func TestRollbackIsBehindTheDeviceToken(t *testing.T) {
	tempState(t)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	if rec := rollbackRequest(h, "", `{"generation": 1}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("rollback without a token = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestRollbackRefusesAGenerationThatDoesNotExist(t *testing.T) {
	tempState(t)
	h := &HAHub{token: "tok", pair: NewPairing("tok")}

	rec := rollbackRequest(h, "tok", `{"generation": 999999}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("rollback to a missing generation = %d, want %d (%s)", rec.Code, http.StatusBadRequest, rec.Body)
	}
}
