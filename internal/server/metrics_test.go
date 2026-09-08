package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetricsAreLocalAndPrivacySafe(t *testing.T) {
	now := time.Unix(1_000, 0)
	metrics := newMetrics(func() time.Time {
		return now
	})
	store := NewStore()
	handler := NewHandlerWithMetrics(store, metrics)

	requestWithRemote(
		handler,
		"/healthz",
		"127.0.0.1:41000",
	)
	requestWithRemote(
		handler,
		"/readyz",
		"127.0.0.1:41000",
	)
	metrics.RecordPolicyReload(PolicyReloadUpdated)
	metrics.RecordPolicyReload(PolicyReloadRejected)
	metrics.RecordTLSReload(TLSReloadUpdated)
	metrics.RecordTLSReload(TLSReloadRejected)

	now = time.Unix(1_005, 0)
	response := requestWithRemote(
		handler,
		"/metrics",
		"[::1]:41000",
	)

	if response.Code != http.StatusOK {
		t.Fatalf(
			"metrics status = %d; expected %d",
			response.Code,
			http.StatusOK,
		)
	}
	if got := response.Header().Get("Content-Type"); got != "text/plain; version=0.0.4; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}

	body := response.Body.String()
	for _, expected := range []string{
		"shieldward_control_plane_process_uptime_seconds 5",
		"shieldward_control_plane_ready 0",
		`shieldward_control_plane_http_requests_total{route="health",status="200"} 1`,
		`shieldward_control_plane_http_requests_total{route="ready",status="503"} 1`,
		`shieldward_control_plane_policy_reload_total{result="updated"} 1`,
		`shieldward_control_plane_policy_reload_total{result="rejected"} 1`,
		`shieldward_control_plane_tls_reload_total{result="updated"} 1`,
		`shieldward_control_plane_tls_reload_total{result="rejected"} 1`,
		"shieldward_control_plane_metrics_scrapes_total 1",
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("metrics do not contain %q", expected)
		}
	}

	for _, forbidden := range []string{
		"authorization",
		"client_ip",
		"request_path",
	} {
		if strings.Contains(strings.ToLower(body), forbidden) {
			t.Errorf("metrics unexpectedly contain %q", forbidden)
		}
	}

	remote := requestWithRemote(
		handler,
		"/metrics",
		"203.0.113.10:41000",
	)
	if remote.Code != http.StatusNotFound {
		t.Fatalf(
			"remote metrics status = %d; expected %d",
			remote.Code,
			http.StatusNotFound,
		)
	}
}

func TestMetricsReportReadyPolicy(t *testing.T) {
	metrics := newMetrics(time.Now)
	store := NewStore()
	envelope := storeTestEnvelope(
		t,
		"https://ready-metrics.internal",
	)
	if err := store.Publish(envelope); err != nil {
		t.Fatalf("Publish() failed: %v", err)
	}

	response := requestWithRemote(
		NewHandlerWithMetrics(store, metrics),
		"/metrics",
		"127.0.0.1:41000",
	)

	if !strings.Contains(
		response.Body.String(),
		"shieldward_control_plane_ready 1",
	) {
		t.Fatal("metrics do not report a ready policy")
	}
}

func TestMetricsWrapperPreservesMissingStreamingSupport(t *testing.T) {
	store := NewStore()
	handler := NewHandlerWithMetrics(
		store,
		newMetrics(time.Now),
	)
	request := httptest.NewRequest(
		http.MethodGet,
		"/v1/events",
		nil,
	)
	writer := &nonFlushingResponseWriter{
		header: make(http.Header),
	}

	handler.ServeHTTP(writer, request)

	if writer.status != http.StatusInternalServerError {
		t.Fatalf(
			"event status = %d; expected %d",
			writer.status,
			http.StatusInternalServerError,
		)
	}
}

func requestWithRemote(
	handler http.Handler,
	path string,
	remoteAddress string,
) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.RemoteAddr = remoteAddress
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

type nonFlushingResponseWriter struct {
	header http.Header
	status int
}

func (writer *nonFlushingResponseWriter) Header() http.Header {
	return writer.header
}

func (writer *nonFlushingResponseWriter) WriteHeader(status int) {
	writer.status = status
}

func (writer *nonFlushingResponseWriter) Write(body []byte) (int, error) {
	return io.Discard.Write(body)
}
