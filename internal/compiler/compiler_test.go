package compiler

import (
	"regexp"
	"strings"
	"testing"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
)

func TestCompileBuildsSingleMatcherPerMethod(t *testing.T) {
	bundle, err := Compile(compilerTestDocument())
	if err != nil {
		t.Fatalf("Compile() returned unexpected error: %v", err)
	}

	if len(bundle.Matchers) != 2 {
		t.Fatalf(
			"len(Matchers) = %d; expected 2",
			len(bundle.Matchers),
		)
	}

	getMatcher := findMatcher(t, bundle, "GET")

	tests := []struct {
		path        string
		wantRouteID string
	}{
		{path: "/v1/users", wantRouteID: "users-list"},
		{path: "/v1/users/42", wantRouteID: "users-read"},
		{path: "/assets/css/app.css", wantRouteID: "assets"},
		{path: "/v1/users/42/extra", wantRouteID: ""},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			got := matchRoute(t, getMatcher, test.path)
			if got != test.wantRouteID {
				t.Fatalf(
					"matched route = %q; expected %q",
					got,
					test.wantRouteID,
				)
			}
		})
	}
}

func TestCompileProducesDeterministicVersion(t *testing.T) {
	first, err := Compile(compilerTestDocument())
	if err != nil {
		t.Fatalf("first Compile() failed: %v", err)
	}

	second, err := Compile(compilerTestDocument())
	if err != nil {
		t.Fatalf("second Compile() failed: %v", err)
	}

	if first.Version != second.Version {
		t.Fatalf(
			"versions differ: %q != %q",
			first.Version,
			second.Version,
		)
	}

	if !strings.HasPrefix(first.Version, "sha256:") ||
		len(first.Version) != len("sha256:")+64 {
		t.Fatalf("unexpected version format %q", first.Version)
	}

	changedDocument := compilerTestDocument()
	changedDocument.Spec.Routes[0].Upstream =
		"https://replacement.internal"

	changed, err := Compile(changedDocument)
	if err != nil {
		t.Fatalf("changed Compile() failed: %v", err)
	}

	if changed.Version == first.Version {
		t.Fatal("version did not change when policy content changed")
	}
}

func TestCompileRejectsDuplicateMethodAndPath(t *testing.T) {
	document := compilerTestDocument()
	document.Spec.Routes = append(document.Spec.Routes, policy.Route{
		ID: "users-copy",
		Match: policy.RouteMatch{
			Methods: []string{"GET"},
			Path:    "/v1/users",
		},
		Upstream: "https://copy.internal",
	})

	if _, err := Compile(document); err == nil {
		t.Fatal("Compile() returned nil; expected route collision error")
	}
}

func TestCompileRejectsNonFinalWildcard(t *testing.T) {
	document := compilerTestDocument()
	document.Spec.Routes[0].Match.Path = "/assets/*/thumbnail"

	if _, err := Compile(document); err == nil {
		t.Fatal("Compile() returned nil; expected wildcard error")
	}
}

func findMatcher(
	t *testing.T,
	bundle Bundle,
	method string,
) MethodMatcher {
	t.Helper()

	for _, matcher := range bundle.Matchers {
		if matcher.Method == method {
			return matcher
		}
	}

	t.Fatalf("matcher for %s was not found", method)
	return MethodMatcher{}
}

func matchRoute(
	t *testing.T,
	matcher MethodMatcher,
	path string,
) string {
	t.Helper()

	expression := regexp.MustCompile(matcher.Regex)
	matches := expression.FindStringSubmatch(path)

	if matches == nil {
		return ""
	}

	for index, value := range matches[1:] {
		if value != "" {
			return matcher.RouteIDs[index]
		}
	}

	return ""
}

func compilerTestDocument() policy.Document {
	return policy.Document{
		APIVersion: policy.APIVersionV1Alpha1,
		Kind:       policy.KindSecurityPolicy,
		Metadata: policy.Metadata{
			Name: "users-api",
		},
		Spec: policy.Spec{
			DefaultDecision: policy.DecisionDeny,
			Routes: []policy.Route{
				{
					ID: "users-list",
					Match: policy.RouteMatch{
						Methods: []string{"GET"},
						Path:    "/v1/users",
					},
					Upstream: "https://users.internal",
				},
				{
					ID: "users-read",
					Match: policy.RouteMatch{
						Methods: []string{"GET"},
						Path:    "/v1/users/:id",
					},
					Upstream: "https://users.internal",
				},
				{
					ID: "users-create",
					Match: policy.RouteMatch{
						Methods: []string{"POST"},
						Path:    "/v1/users",
					},
					Upstream: "https://users.internal",
				},
				{
					ID: "assets",
					Match: policy.RouteMatch{
						Methods: []string{"GET"},
						Path:    "/assets/*",
					},
					Upstream: "https://assets.internal",
				},
			},
		},
	}
}
