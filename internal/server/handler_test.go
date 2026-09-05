package server

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHandlerHealthAndReadiness(t *testing.T) {
	store := NewStore()
	handler := NewHandler(store)

	health := performRequest(handler, "/healthz", "")
	if health.Code != http.StatusOK {
		t.Fatalf(
			"health status = %d; expected %d",
			health.Code,
			http.StatusOK,
		)
	}

	notReady := performRequest(handler, "/readyz", "")
	if notReady.Code != http.StatusServiceUnavailable {
		t.Fatalf(
			"empty readiness status = %d; expected %d",
			notReady.Code,
			http.StatusServiceUnavailable,
		)
	}

	envelope := storeTestEnvelope(t, "https://ready.internal")
	if err := store.Publish(envelope); err != nil {
		t.Fatalf("Publish() failed: %v", err)
	}

	ready := performRequest(handler, "/readyz", "")
	if ready.Code != http.StatusOK {
		t.Fatalf(
			"ready status = %d; expected %d",
			ready.Code,
			http.StatusOK,
		)
	}

	if !strings.Contains(ready.Body.String(), envelope.Bundle.Version) {
		t.Fatal("readiness response does not contain bundle version")
	}
}

func TestHandlerServesBundleWithETag(t *testing.T) {
	store := NewStore()
	envelope := storeTestEnvelope(t, "https://bundle.internal")

	if err := store.Publish(envelope); err != nil {
		t.Fatalf("Publish() failed: %v", err)
	}

	handler := NewHandler(store)
	response := performRequest(handler, "/v1/bundle", "")

	if response.Code != http.StatusOK {
		t.Fatalf(
			"bundle status = %d; expected %d",
			response.Code,
			http.StatusOK,
		)
	}

	etag := response.Header().Get("ETag")
	if etag == "" {
		t.Fatal("bundle response has no ETag")
	}

	if !strings.Contains(response.Body.String(), envelope.Bundle.Version) {
		t.Fatal("bundle response does not contain expected version")
	}

	notModified := performRequest(handler, "/v1/bundle", etag)
	if notModified.Code != http.StatusNotModified {
		t.Fatalf(
			"conditional status = %d; expected %d",
			notModified.Code,
			http.StatusNotModified,
		)
	}

	if notModified.Body.Len() != 0 {
		t.Fatal("304 response unexpectedly contains a body")
	}
}

func TestHandlerStreamsCurrentBundleVersion(t *testing.T) {
	store := NewStore()
	envelope := storeTestEnvelope(t, "https://stream.internal")

	if err := store.Publish(envelope); err != nil {
		t.Fatalf("Publish() failed: %v", err)
	}

	testServer := httptest.NewServer(NewHandler(store))
	defer testServer.Close()

	ctx, cancel := context.WithTimeout(
		context.Background(),
		2*time.Second,
	)
	defer cancel()

	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		testServer.URL+"/v1/events",
		nil,
	)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}

	response, err := testServer.Client().Do(request)
	if err != nil {
		t.Fatalf("request event stream: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf(
			"event status = %d; expected %d",
			response.StatusCode,
			http.StatusOK,
		)
	}

	if contentType := response.Header.Get("Content-Type"); contentType != "text/event-stream" {
		t.Fatalf(
			"Content-Type = %q; expected text/event-stream",
			contentType,
		)
	}

	reader := bufio.NewReader(response.Body)

	eventLine, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read event line: %v", err)
	}

	dataLine, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read data line: %v", err)
	}

	if strings.TrimSpace(eventLine) != "event: bundle" {
		t.Fatalf("unexpected event line %q", eventLine)
	}

	data := strings.TrimSpace(
		strings.TrimPrefix(dataLine, "data:"),
	)

	var payload map[string]string
	if err := json.Unmarshal([]byte(data), &payload); err != nil {
		t.Fatalf("decode event data: %v", err)
	}

	if payload["version"] != envelope.Bundle.Version {
		t.Fatalf(
			"event version = %q; expected %q",
			payload["version"],
			envelope.Bundle.Version,
		)
	}

	cancel()
}

func performRequest(
	handler http.Handler,
	path string,
	ifNoneMatch string,
) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, path, nil)

	if ifNoneMatch != "" {
		request.Header.Set("If-None-Match", ifNoneMatch)
	}

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	return response
}
