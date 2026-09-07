package main

import (
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunProbeReportsHealthyEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.Path != "/readyz" {
				t.Fatalf("path = %q; expected /readyz", request.URL.Path)
			}
			writer.WriteHeader(http.StatusOK)
		},
	))
	defer server.Close()

	var stdout strings.Builder
	err := runProbe(
		[]string{"-url", server.URL + "/readyz"},
		&stdout,
		io.Discard,
	)
	if err != nil {
		t.Fatalf("runProbe() error = %v", err)
	}
	if stdout.String() != "healthy status=200\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestRunProbeRejectsNotReadyEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusServiceUnavailable)
		},
	))
	defer server.Close()

	err := runProbe(
		[]string{"-url", server.URL},
		io.Discard,
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatalf("runProbe() error = %v; expected HTTP 503", err)
	}
}

func TestRunProbeTrustsConfiguredCA(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusOK)
		},
	))
	defer server.Close()

	certificatePEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: server.Certificate().Raw,
	})
	caPath := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(caPath, certificatePEM, 0o600); err != nil {
		t.Fatalf("write CA certificate: %v", err)
	}

	err := runProbe(
		[]string{"-url", server.URL, "-ca", caPath},
		io.Discard,
		io.Discard,
	)
	if err != nil {
		t.Fatalf("runProbe() error = %v", err)
	}
}

func TestParseProbeURLFailsClosed(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		wantErr string
	}{
		{
			name:    "relative URL",
			value:   "/readyz",
			wantErr: "absolute HTTP or HTTPS URL",
		},
		{
			name:    "remote cleartext URL",
			value:   "http://control-plane.example/readyz",
			wantErr: "must use HTTPS unless it targets loopback",
		},
		{
			name:    "embedded credentials",
			value:   "https://user:secret@control-plane.example/readyz",
			wantErr: "must not contain credentials",
		},
		{
			name:    "fragment",
			value:   "https://control-plane.example/readyz#details",
			wantErr: "must not contain a fragment",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseProbeURL(test.value)
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf(
					"parseProbeURL() error = %v; expected %q",
					err,
					test.wantErr,
				)
			}
		})
	}
}
