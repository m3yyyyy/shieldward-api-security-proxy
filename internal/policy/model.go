package policy

const (
	APIVersionV1Alpha1 = "shieldward.dev/v1alpha1"
	KindSecurityPolicy = "SecurityPolicy"

	DecisionAllow = "allow"
	DecisionDeny  = "deny"

	WAFActionBlock = "block"
	WAFActionLog   = "log"
)

// Document is the declarative policy supplied by a ShieldWard operator.
type Document struct {
	APIVersion string   `json:"apiVersion" yaml:"apiVersion" toml:"apiVersion"`
	Kind       string   `json:"kind" yaml:"kind" toml:"kind"`
	Metadata   Metadata `json:"metadata" yaml:"metadata" toml:"metadata"`
	Spec       Spec     `json:"spec" yaml:"spec" toml:"spec"`
}

type Metadata struct {
	Name string `json:"name" yaml:"name" toml:"name"`
}

type Spec struct {
	DefaultDecision string  `json:"defaultDecision" yaml:"defaultDecision" toml:"defaultDecision"`
	Routes          []Route `json:"routes" yaml:"routes" toml:"routes"`
}

type Route struct {
	ID        string           `json:"id" yaml:"id" toml:"id"`
	Match     RouteMatch       `json:"match" yaml:"match" toml:"match"`
	Upstream  string           `json:"upstream" yaml:"upstream" toml:"upstream"`
	JWT       *JWTPolicy       `json:"jwt,omitempty" yaml:"jwt,omitempty" toml:"jwt,omitempty"`
	RateLimit *RateLimitPolicy `json:"rateLimit,omitempty" yaml:"rateLimit,omitempty" toml:"rateLimit,omitempty"`
	WAF       []WAFRule        `json:"waf,omitempty" yaml:"waf,omitempty" toml:"waf,omitempty"`
}

type RouteMatch struct {
	Methods []string `json:"methods" yaml:"methods" toml:"methods"`
	Path    string   `json:"path" yaml:"path" toml:"path"`
}

type JWTPolicy struct {
	Required bool     `json:"required" yaml:"required" toml:"required"`
	Issuer   string   `json:"issuer" yaml:"issuer" toml:"issuer"`
	Audience []string `json:"audience" yaml:"audience" toml:"audience"`
	JWKSURL  string   `json:"jwksUrl" yaml:"jwksUrl" toml:"jwksUrl"`
}

type RateLimitPolicy struct {
	Requests int    `json:"requests" yaml:"requests" toml:"requests"`
	Window   string `json:"window" yaml:"window" toml:"window"`
	Key      string `json:"key" yaml:"key" toml:"key"`
}

type WAFRule struct {
	ID      string `json:"id" yaml:"id" toml:"id"`
	Target  string `json:"target" yaml:"target" toml:"target"`
	Pattern string `json:"pattern" yaml:"pattern" toml:"pattern"`
	Flags   string `json:"flags,omitempty" yaml:"flags,omitempty" toml:"flags,omitempty"`
	Action  string `json:"action" yaml:"action" toml:"action"`
}
