package policy

import (
	"strings"
	"testing"
)

func TestValidateAcceptsValidPolicy(t *testing.T) {
	if err := Validate(validDocument()); err != nil {
		t.Fatalf("Validate() returned unexpected error: %v", err)
	}
}

func TestValidateRejectsUnsafePolicies(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*Document)
		wantErr string
	}{
		{
			name: "unknown API version",
			mutate: func(document *Document) {
				document.APIVersion = "shieldward.dev/v2"
			},
			wantErr: "apiVersion",
		},
		{
			name: "duplicate route ID",
			mutate: func(document *Document) {
				document.Spec.Routes = append(
					document.Spec.Routes,
					document.Spec.Routes[0],
				)
			},
			wantErr: "duplicated",
		},
		{
			name: "lowercase HTTP method",
			mutate: func(document *Document) {
				document.Spec.Routes[0].Match.Methods = []string{"get"}
			},
			wantErr: "non-uppercase",
		},
		{
			name: "insecure JWKS URL",
			mutate: func(document *Document) {
				document.Spec.Routes[0].JWT.JWKSURL =
					"http://identity.example.com/jwks.json"
			},
			wantErr: "must use HTTPS",
		},
		{
			name: "insecure remote upstream URL",
			mutate: func(document *Document) {
				document.Spec.Routes[0].Upstream =
					"http://orders.internal"
			},
			wantErr: "must use HTTPS unless it targets loopback",
		},
		{
			name: "JWT rate-limit key without JWT",
			mutate: func(document *Document) {
				document.Spec.Routes[0].JWT = nil
			},
			wantErr: "requires jwt configuration",
		},
		{
			name: "invalid WAF expression",
			mutate: func(document *Document) {
				document.Spec.Routes[0].WAF[0].Pattern = "[unclosed"
			},
			wantErr: "pattern is invalid",
		},
		{
			name: "unsupported WAF flags",
			mutate: func(document *Document) {
				document.Spec.Routes[0].WAF[0].Flags = "g"
			},
			wantErr: "flags must be empty or",
		},
		{
			name: "inline WAF flags",
			mutate: func(document *Document) {
				document.Spec.Routes[0].WAF[0].Pattern = `(?i)admin`
			},
			wantErr: "portable regular-expression subset",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			document := validDocument()
			test.mutate(&document)

			err := Validate(document)
			if err == nil {
				t.Fatal("Validate() returned nil; expected an error")
			}

			if !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf(
					"Validate() error = %q; expected it to contain %q",
					err,
					test.wantErr,
				)
			}
		})
	}
}

func validDocument() Document {
	return Document{
		APIVersion: APIVersionV1Alpha1,
		Kind:       KindSecurityPolicy,
		Metadata: Metadata{
			Name: "orders-api",
		},
		Spec: Spec{
			DefaultDecision: DecisionDeny,
			Routes: []Route{
				{
					ID: "orders-read",
					Match: RouteMatch{
						Methods: []string{"GET"},
						Path:    "/v1/orders/:id",
					},
					Upstream: "https://orders.internal",
					JWT: &JWTPolicy{
						Required: true,
						Issuer:   "https://identity.example.com/",
						Audience: []string{"orders-api"},
						JWKSURL:  "https://identity.example.com/jwks.json",
					},
					RateLimit: &RateLimitPolicy{
						Requests: 100,
						Window:   "1m",
						Key:      "jwt.sub",
					},
					WAF: []WAFRule{
						{
							ID:      "block-path-traversal",
							Target:  "path",
							Pattern: `(\.\./|%2e%2e)`,
							Flags:   "i",
							Action:  WAFActionBlock,
						},
					},
				},
			},
		},
	}
}
