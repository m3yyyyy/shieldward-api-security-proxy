package main

import (
	"strings"
	"testing"
)

func TestValidateServeTransportAllowsLoopbackHTTP(t *testing.T) {
	tlsEnabled, err := validateServeTransport(
		"127.0.0.1:18080",
		"",
		"",
	)
	if err != nil {
		t.Fatalf("validateServeTransport() returned unexpected error: %v", err)
	}
	if tlsEnabled {
		t.Fatal("validateServeTransport() enabled TLS without certificate files")
	}
}

func TestValidateServeTransportAllowsConfiguredTLS(t *testing.T) {
	tlsEnabled, err := validateServeTransport(
		"0.0.0.0:18080",
		"tls/certificate.pem",
		"tls/private-key.pem",
	)
	if err != nil {
		t.Fatalf("validateServeTransport() returned unexpected error: %v", err)
	}
	if !tlsEnabled {
		t.Fatal("validateServeTransport() did not enable TLS")
	}
}

func TestValidateServeTransportRejectsUnsafeSettings(t *testing.T) {
	tests := []struct {
		name        string
		listen      string
		certificate string
		privateKey  string
		wantErr     string
	}{
		{
			name:    "remote HTTP listener",
			listen:  "0.0.0.0:18080",
			wantErr: "TLS certificate and key are required",
		},
		{
			name:        "certificate without key",
			listen:      "127.0.0.1:18080",
			certificate: "tls/certificate.pem",
			wantErr:     "must be configured together",
		},
		{
			name:       "key without certificate",
			listen:     "127.0.0.1:18080",
			privateKey: "tls/private-key.pem",
			wantErr:    "must be configured together",
		},
		{
			name:    "invalid listen address",
			listen:  "not-an-address",
			wantErr: "parse listen address",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := validateServeTransport(
				test.listen,
				test.certificate,
				test.privateKey,
			)
			if err == nil {
				t.Fatal("validateServeTransport() returned nil; expected an error")
			}
			if !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf(
					"validateServeTransport() error = %q; expected it to contain %q",
					err,
					test.wantErr,
				)
			}
		})
	}
}
