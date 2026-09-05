package policy

import (
	"bytes"
	"testing"
)

const validYAML = `
apiVersion: shieldward.dev/v1alpha1
kind: SecurityPolicy
metadata:
  name: orders-api
spec:
  defaultDecision: deny
  routes:
    - id: orders-read
      match:
        methods:
          - GET
        path: /v1/orders/:id
      upstream: https://orders.internal
`

const validTOML = `
apiVersion = "shieldward.dev/v1alpha1"
kind = "SecurityPolicy"

[metadata]
name = "orders-api"

[spec]
defaultDecision = "deny"

[[spec.routes]]
id = "orders-read"
upstream = "https://orders.internal"

[spec.routes.match]
methods = ["GET"]
path = "/v1/orders/:id"
`

func TestParseAcceptsSupportedFormats(t *testing.T) {
	tests := []struct {
		name   string
		format string
		input  string
	}{
		{
			name:   "YAML",
			format: ".yaml",
			input:  validYAML,
		},
		{
			name:   "TOML",
			format: "toml",
			input:  validTOML,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			document, err := Parse([]byte(test.input), test.format)
			if err != nil {
				t.Fatalf("Parse() returned unexpected error: %v", err)
			}

			if document.Metadata.Name != "orders-api" {
				t.Fatalf(
					"Metadata.Name = %q; expected %q",
					document.Metadata.Name,
					"orders-api",
				)
			}

			if len(document.Spec.Routes) != 1 {
				t.Fatalf(
					"len(Spec.Routes) = %d; expected 1",
					len(document.Spec.Routes),
				)
			}
		})
	}
}

func TestParseRejectsUnknownFields(t *testing.T) {
	tests := []struct {
		name   string
		format string
		input  string
	}{
		{
			name:   "YAML",
			format: "yaml",
			input:  "unexpected: true\n" + validYAML,
		},
		{
			name:   "TOML",
			format: "toml",
			input:  "unexpected = true\n" + validTOML,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := Parse([]byte(test.input), test.format); err == nil {
				t.Fatal("Parse() returned nil; expected unknown field error")
			}
		})
	}
}

func TestParseRejectsMultipleYAMLDocuments(t *testing.T) {
	input := validYAML + "\n---\n" + validYAML

	_, err := Parse([]byte(input), "yaml")
	if err == nil {
		t.Fatal("Parse() returned nil; expected multiple document error")
	}
}

func TestParseRejectsOversizedDocument(t *testing.T) {
	input := bytes.Repeat([]byte{'x'}, MaxDocumentBytes+1)

	_, err := Parse(input, "yaml")
	if err == nil {
		t.Fatal("Parse() returned nil; expected size-limit error")
	}
}

func TestParseRejectsUnsupportedFormat(t *testing.T) {
	_, err := Parse([]byte(`{}`), "json")
	if err == nil {
		t.Fatal("Parse() returned nil; expected unsupported format error")
	}
}
