package compiler

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/canonicaljson"
	"github.com/m3yyyyy/shieldward-api-security-proxy/internal/policy"
)

const BundleSchemaVersion = "shieldward.bundle/v1alpha1"

var parameterPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

type Bundle struct {
	SchemaVersion   string          `json:"schemaVersion"`
	PolicyName      string          `json:"policyName"`
	DefaultDecision string          `json:"defaultDecision"`
	Matchers        []MethodMatcher `json:"matchers"`
	Routes          []CompiledRoute `json:"routes"`
	Version         string          `json:"version,omitempty"`
}

type MethodMatcher struct {
	Method   string   `json:"method"`
	Regex    string   `json:"regex"`
	RouteIDs []string `json:"routeIds"`
}

type CompiledRoute struct {
	ID        string                  `json:"id"`
	Match     policy.RouteMatch       `json:"match"`
	Upstream  string                  `json:"upstream"`
	JWT       *policy.JWTPolicy       `json:"jwt,omitempty"`
	RateLimit *policy.RateLimitPolicy `json:"rateLimit,omitempty"`
	WAF       []policy.WAFRule        `json:"waf,omitempty"`
}

type routePattern struct {
	routeID string
	pattern string
}

func Compile(document policy.Document) (Bundle, error) {
	if err := policy.Validate(document); err != nil {
		return Bundle{}, fmt.Errorf("validate source policy: %w", err)
	}

	matchers, err := compileMatchers(document.Spec.Routes)
	if err != nil {
		return Bundle{}, err
	}

	routes := make([]CompiledRoute, 0, len(document.Spec.Routes))
	for _, route := range document.Spec.Routes {
		routes = append(routes, cloneRoute(route))
	}

	bundle := Bundle{
		SchemaVersion:   BundleSchemaVersion,
		PolicyName:      document.Metadata.Name,
		DefaultDecision: document.Spec.DefaultDecision,
		Matchers:        matchers,
		Routes:          routes,
	}

	canonical, err := canonicaljson.Marshal(bundle)
	if err != nil {
		return Bundle{}, fmt.Errorf("canonicalize bundle: %w", err)
	}

	digest := sha256.Sum256(canonical)
	bundle.Version = fmt.Sprintf("sha256:%x", digest)

	return bundle, nil
}

func compileMatchers(routes []policy.Route) ([]MethodMatcher, error) {
	byMethod := make(map[string][]routePattern)
	seen := make(map[string]string)

	for _, route := range routes {
		pattern, err := compilePathTemplate(route.Match.Path)
		if err != nil {
			return nil, fmt.Errorf(
				"compile route %q path: %w",
				route.ID,
				err,
			)
		}

		for _, method := range route.Match.Methods {
			key := method + "\x00" + route.Match.Path
			if existingID, exists := seen[key]; exists {
				return nil, fmt.Errorf(
					"routes %q and %q use the same method and path",
					existingID,
					route.ID,
				)
			}
			seen[key] = route.ID

			byMethod[method] = append(
				byMethod[method],
				routePattern{
					routeID: route.ID,
					pattern: pattern,
				},
			)
		}
	}

	methods := make([]string, 0, len(byMethod))
	for method := range byMethod {
		methods = append(methods, method)
	}
	sort.Strings(methods)

	matchers := make([]MethodMatcher, 0, len(methods))
	for _, method := range methods {
		patterns := byMethod[method]
		alternatives := make([]string, 0, len(patterns))
		routeIDs := make([]string, 0, len(patterns))

		for _, candidate := range patterns {
			alternatives = append(
				alternatives,
				"("+candidate.pattern+")",
			)
			routeIDs = append(routeIDs, candidate.routeID)
		}

		combined := "^(?:" + strings.Join(alternatives, "|") + ")$"
		if _, err := regexp.Compile(combined); err != nil {
			return nil, fmt.Errorf(
				"compile %s matcher: %w",
				method,
				err,
			)
		}

		matchers = append(matchers, MethodMatcher{
			Method:   method,
			Regex:    combined,
			RouteIDs: routeIDs,
		})
	}

	return matchers, nil
}

func compilePathTemplate(path string) (string, error) {
	if path == "/" {
		return "/", nil
	}

	segments := strings.Split(strings.TrimPrefix(path, "/"), "/")
	var result strings.Builder

	for index, segment := range segments {
		result.WriteByte('/')

		switch {
		case strings.HasPrefix(segment, ":"):
			name := strings.TrimPrefix(segment, ":")
			if !parameterPattern.MatchString(name) {
				return "", fmt.Errorf(
					"invalid path parameter %q",
					segment,
				)
			}
			result.WriteString("[^/]+")

		case segment == "*":
			if index != len(segments)-1 {
				return "", fmt.Errorf(
					"wildcard must be the final path segment",
				)
			}
			result.WriteString(".*")

		case strings.Contains(segment, "*"):
			return "", fmt.Errorf(
				"wildcards must occupy an entire path segment",
			)

		default:
			result.WriteString(regexp.QuoteMeta(segment))
		}
	}

	return result.String(), nil
}

func cloneRoute(route policy.Route) CompiledRoute {
	compiled := CompiledRoute{
		ID: route.ID,
		Match: policy.RouteMatch{
			Methods: append([]string(nil), route.Match.Methods...),
			Path:    route.Match.Path,
		},
		Upstream: route.Upstream,
		WAF:      append([]policy.WAFRule(nil), route.WAF...),
	}

	if route.JWT != nil {
		jwtPolicy := *route.JWT
		jwtPolicy.Audience = append([]string(nil), route.JWT.Audience...)
		compiled.JWT = &jwtPolicy
	}

	if route.RateLimit != nil {
		rateLimit := *route.RateLimit
		compiled.RateLimit = &rateLimit
	}

	return compiled
}
