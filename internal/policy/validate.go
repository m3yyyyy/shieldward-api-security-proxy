package policy

import (
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var identifierPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,62}$`)

var allowedMethods = map[string]struct{}{
	"DELETE":  {},
	"GET":     {},
	"HEAD":    {},
	"OPTIONS": {},
	"PATCH":   {},
	"POST":    {},
	"PUT":     {},
}

func Validate(document Document) error {
	if document.APIVersion != APIVersionV1Alpha1 {
		return fmt.Errorf("apiVersion must be %q", APIVersionV1Alpha1)
	}

	if document.Kind != KindSecurityPolicy {
		return fmt.Errorf("kind must be %q", KindSecurityPolicy)
	}

	if !identifierPattern.MatchString(document.Metadata.Name) {
		return fmt.Errorf("metadata.name must be a lowercase DNS-style identifier")
	}

	if document.Spec.DefaultDecision != DecisionAllow &&
		document.Spec.DefaultDecision != DecisionDeny {
		return fmt.Errorf("spec.defaultDecision must be %q or %q", DecisionAllow, DecisionDeny)
	}

	if len(document.Spec.Routes) == 0 {
		return fmt.Errorf("spec.routes must contain at least one route")
	}

	routeIDs := make(map[string]struct{}, len(document.Spec.Routes))

	for index, route := range document.Spec.Routes {
		location := fmt.Sprintf("spec.routes[%d]", index)

		if !identifierPattern.MatchString(route.ID) {
			return fmt.Errorf("%s.id must be a lowercase DNS-style identifier", location)
		}

		if _, exists := routeIDs[route.ID]; exists {
			return fmt.Errorf("%s.id %q is duplicated", location, route.ID)
		}
		routeIDs[route.ID] = struct{}{}

		if err := validateRoute(location, route); err != nil {
			return err
		}
	}

	return nil
}

func validateRoute(location string, route Route) error {
	if len(route.Match.Methods) == 0 {
		return fmt.Errorf("%s.match.methods must not be empty", location)
	}

	methods := make(map[string]struct{}, len(route.Match.Methods))
	for _, method := range route.Match.Methods {
		if method != strings.ToUpper(method) {
			return fmt.Errorf("%s.match.methods contains non-uppercase method %q", location, method)
		}

		if _, allowed := allowedMethods[method]; !allowed {
			return fmt.Errorf("%s.match.methods contains unsupported method %q", location, method)
		}

		if _, exists := methods[method]; exists {
			return fmt.Errorf("%s.match.methods contains duplicate method %q", location, method)
		}
		methods[method] = struct{}{}
	}

	if !strings.HasPrefix(route.Match.Path, "/") {
		return fmt.Errorf("%s.match.path must begin with /", location)
	}

	if err := validateHTTPURL(route.Upstream, false); err != nil {
		return fmt.Errorf("%s.upstream: %w", location, err)
	}

	if route.JWT != nil {
		if !route.JWT.Required {
			return fmt.Errorf("%s.jwt.required must be true when jwt is configured", location)
		}

		if err := validateHTTPURL(route.JWT.Issuer, true); err != nil {
			return fmt.Errorf("%s.jwt.issuer: %w", location, err)
		}

		if len(route.JWT.Audience) == 0 {
			return fmt.Errorf("%s.jwt.audience must not be empty", location)
		}

		if err := validateHTTPURL(route.JWT.JWKSURL, true); err != nil {
			return fmt.Errorf("%s.jwt.jwksUrl: %w", location, err)
		}
	}

	if route.RateLimit != nil {
		if route.RateLimit.Requests <= 0 {
			return fmt.Errorf("%s.rateLimit.requests must be positive", location)
		}

		window, err := time.ParseDuration(route.RateLimit.Window)
		if err != nil || window <= 0 {
			return fmt.Errorf("%s.rateLimit.window must be a positive duration", location)
		}

		switch route.RateLimit.Key {
		case "client-ip":
		case "jwt.sub":
			if route.JWT == nil {
				return fmt.Errorf("%s.rateLimit.key jwt.sub requires jwt configuration", location)
			}
		default:
			return fmt.Errorf("%s.rateLimit.key is unsupported", location)
		}
	}

	wafIDs := make(map[string]struct{}, len(route.WAF))
	for index, rule := range route.WAF {
		ruleLocation := fmt.Sprintf("%s.waf[%d]", location, index)

		if !identifierPattern.MatchString(rule.ID) {
			return fmt.Errorf("%s.id must be a lowercase DNS-style identifier", ruleLocation)
		}

		if _, exists := wafIDs[rule.ID]; exists {
			return fmt.Errorf("%s.id %q is duplicated", ruleLocation, rule.ID)
		}
		wafIDs[rule.ID] = struct{}{}

		switch rule.Target {
		case "path", "query", "headers", "body":
		default:
			return fmt.Errorf("%s.target is unsupported", ruleLocation)
		}

		switch rule.Flags {
		case "", "i":
		default:
			return fmt.Errorf(
				"%s.flags must be empty or %q",
				ruleLocation,
				"i",
			)
		}

		if strings.Contains(rule.Pattern, "(?") {
			return fmt.Errorf(
				"%s.pattern must use the portable regular-expression subset",
				ruleLocation,
			)
		}

		validationPattern := rule.Pattern
		if rule.Flags == "i" {
			validationPattern = "(?i:" + rule.Pattern + ")"
		}

		if _, err := regexp.Compile(validationPattern); err != nil {
			return fmt.Errorf("%s.pattern is invalid: %w", ruleLocation, err)
		}

		if rule.Action != WAFActionBlock && rule.Action != WAFActionLog {
			return fmt.Errorf("%s.action must be %q or %q", ruleLocation, WAFActionBlock, WAFActionLog)
		}
	}

	return nil
}

func validateHTTPURL(rawURL string, requireHTTPS bool) error {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("must be an absolute HTTP URL")
	}

	if parsed.User != nil {
		return fmt.Errorf("must not contain embedded credentials")
	}

	if requireHTTPS {
		if parsed.Scheme != "https" {
			return fmt.Errorf("must use HTTPS")
		}
		return nil
	}

	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return fmt.Errorf("must use HTTP or HTTPS")
	}

	if parsed.Scheme == "http" && !isLoopbackHostname(parsed.Hostname()) {
		return fmt.Errorf("must use HTTPS unless it targets loopback")
	}

	return nil
}

func isLoopbackHostname(hostname string) bool {
	if strings.EqualFold(strings.TrimSuffix(hostname, "."), "localhost") {
		return true
	}

	ip := net.ParseIP(hostname)
	return ip != nil && ip.IsLoopback()
}
