package deployment

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v4"
)

func TestDeploymentYAMLParses(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")

	assertYAMLDocuments(t, filepath.Join(repositoryRoot, "compose.yaml"), false)

	workflowPaths, err := filepath.Glob(
		filepath.Join(repositoryRoot, ".github", "workflows", "*.yml"),
	)
	if err != nil {
		t.Fatalf("glob GitHub Actions workflows: %v", err)
	}
	if len(workflowPaths) == 0 {
		t.Fatal("no GitHub Actions workflows found")
	}
	for _, workflowPath := range workflowPaths {
		assertYAMLDocuments(t, workflowPath, false)
	}

	manifestPaths, err := filepath.Glob(
		filepath.Join(repositoryRoot, "deploy", "kubernetes", "*", "*.yaml"),
	)
	if err != nil {
		t.Fatalf("glob Kubernetes manifests: %v", err)
	}
	if len(manifestPaths) == 0 {
		t.Fatal("no Kubernetes manifests found")
	}

	for _, manifestPath := range manifestPaths {
		assertYAMLDocuments(t, manifestPath, true)
	}
}

func TestKustomizationsReferenceExistingFiles(t *testing.T) {
	root := filepath.Join("..", "..", "deploy", "kubernetes")
	directories := []string{
		filepath.Join(root, "base"),
		filepath.Join(root, "redis-rate-limit"),
	}

	for _, directory := range directories {
		t.Run(filepath.Base(directory), func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(directory, "kustomization.yaml"))
			if err != nil {
				t.Fatalf("read kustomization: %v", err)
			}

			var kustomization struct {
				Resources []string `yaml:"resources"`
				Patches   []struct {
					Path string `yaml:"path"`
				} `yaml:"patches"`
			}
			if err := yaml.Unmarshal(contents, &kustomization); err != nil {
				t.Fatalf("decode kustomization: %v", err)
			}
			if len(kustomization.Resources) == 0 {
				t.Fatal("kustomization has no resources")
			}

			for _, resource := range kustomization.Resources {
				assertPathExists(t, directory, resource)
			}
			for _, patch := range kustomization.Patches {
				if patch.Path != "" {
					assertPathExists(t, directory, patch.Path)
				}
			}
		})
	}
}

func TestRedisRateLimitOverlayUsesTLSSecretsAndNarrowEgress(t *testing.T) {
	directory := filepath.Join("..", "..", "deploy", "kubernetes", "redis-rate-limit")
	deployment, err := os.ReadFile(filepath.Join(directory, "edge-rate-limit.yaml"))
	if err != nil {
		t.Fatalf("read Redis deployment patch: %v", err)
	}
	kustomization, err := os.ReadFile(filepath.Join(directory, "kustomization.yaml"))
	if err != nil {
		t.Fatalf("read Redis kustomization: %v", err)
	}

	for _, expected := range []string{
		"replicas: 2",
		"SHIELDWARD_RATE_LIMIT_BACKEND",
		"rediss://",
		"SHIELDWARD_REDIS_PASSWORD_FILE",
		"SHIELDWARD_REDIS_CA_FILE",
	} {
		if !strings.Contains(string(deployment), expected) {
			t.Errorf("Redis deployment patch does not contain %q", expected)
		}
	}

	for _, expected := range []string{
		"app.kubernetes.io/component: rate-limit-store",
		"port: 6379",
	} {
		if !strings.Contains(string(kustomization), expected) {
			t.Errorf("Redis NetworkPolicy patch does not contain %q", expected)
		}
	}
}

func TestRedisIntegrationWorkflowPinsServiceImage(t *testing.T) {
	path := filepath.Join("..", "..", ".github", "workflows", "ci.yml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read CI workflow: %v", err)
	}

	text := string(contents)
	for _, expected := range []string{
		"distributed-rate-limit:",
		"redis:8.10.1-alpine@sha256:",
		"TEST_REDIS_URL: redis://127.0.0.1:6379",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("CI workflow does not contain %q", expected)
		}
	}
}

func TestEdgeDeploymentsSetResilienceBudgets(t *testing.T) {
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("..", "..", "compose.yaml"),
			expected: []string{
				`SHIELDWARD_UPSTREAM_TIMEOUT_MS: "10000"`,
				`SHIELDWARD_MAX_IN_FLIGHT_REQUESTS: "1024"`,
				`SHIELDWARD_CIRCUIT_FAILURE_THRESHOLD: "5"`,
				`SHIELDWARD_CIRCUIT_OPEN_MS: "30000"`,
				`SHIELDWARD_CIRCUIT_MAX_UPSTREAMS: "1024"`,
				`SHIELDWARD_SHUTDOWN_GRACE_MS: "10000"`,
				"stop_grace_period: 15s",
			},
		},
		{
			path: filepath.Join("..", "..", "deploy", "kubernetes", "base", "edge.yaml"),
			expected: []string{
				"SHIELDWARD_UPSTREAM_TIMEOUT_MS",
				"SHIELDWARD_MAX_IN_FLIGHT_REQUESTS",
				"SHIELDWARD_CIRCUIT_FAILURE_THRESHOLD",
				"SHIELDWARD_CIRCUIT_OPEN_MS",
				"SHIELDWARD_CIRCUIT_MAX_UPSTREAMS",
				"SHIELDWARD_SHUTDOWN_GRACE_MS",
				`value: "10000"`,
				`value: "1024"`,
				`value: "5"`,
				`value: "30000"`,
				"terminationGracePeriodSeconds: 20",
			},
		},
	}

	for _, test := range tests {
		t.Run(filepath.Base(test.path), func(t *testing.T) {
			contents, err := os.ReadFile(test.path)
			if err != nil {
				t.Fatalf("read deployment: %v", err)
			}

			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("deployment does not contain %q", expected)
				}
			}
		})
	}
}

func TestDeploymentsRequireMutualTLSServiceIdentity(t *testing.T) {
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("..", "..", "compose.yaml"),
			expected: []string{
				"-client-ca",
				"spiffe://shieldward.local/edge",
				"SHIELDWARD_CONTROL_PLANE_CA_FILE",
				"SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE",
				"SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE",
				`SHIELDWARD_TLS_RELOAD_INTERVAL_MS: "30000"`,
			},
		},
		{
			path: filepath.Join("..", "..", "deploy", "kubernetes", "base", "control-plane.yaml"),
			expected: []string{
				"-client-ca",
				"-client-identity",
				"spiffe://shieldward.local/edge",
				"-tls-reload-interval",
			},
		},
		{
			path: filepath.Join("..", "..", "deploy", "kubernetes", "base", "edge.yaml"),
			expected: []string{
				"SHIELDWARD_CONTROL_PLANE_CA_FILE",
				"SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE",
				"SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE",
				"SHIELDWARD_TLS_RELOAD_INTERVAL_MS",
			},
		},
	}

	for _, test := range tests {
		t.Run(filepath.Base(test.path), func(t *testing.T) {
			contents, err := os.ReadFile(test.path)
			if err != nil {
				t.Fatalf("read deployment: %v", err)
			}

			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("deployment does not contain %q", expected)
				}
			}
		})
	}
}

func TestContainersWorkflowRunsProductionAcceptanceDrill(t *testing.T) {
	path := filepath.Join("..", "..", ".github", "workflows", "containers.yml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read Containers workflow: %v", err)
	}

	text := string(contents)
	for _, expected := range []string{
		"test-production-acceptance.ps1",
		"-IncludeFailureDrills",
		"steps.version.outputs.value",
		"-RequireClean -RequireTag",
		"Show container logs after failure",
		"docker compose down --volumes --remove-orphans",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("Containers workflow does not contain %q", expected)
		}
	}
}

func TestReleaseWorkflowInjectsAndVerifiesVersion(t *testing.T) {
	path := filepath.Join("..", "..", ".github", "workflows", "release.yml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read Release workflow: %v", err)
	}

	text := string(contents)
	for _, expected := range []string{
		"check-release-readiness.ps1",
		"-RequireClean -RequireTag",
		"build-release-assets.sh",
		"verify-release-assets.ps1",
		"gh release create",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("Release workflow does not contain %q", expected)
		}
	}

	buildScriptPath := filepath.Join("..", "..", "scripts", "build-release-assets.sh")
	buildScript, err := os.ReadFile(buildScriptPath)
	if err != nil {
		t.Fatalf("read release build script: %v", err)
	}
	for _, expected := range []string{
		"-X main.version=${version}",
		"--create --file=-",
		"--sort=name",
		"gzip -n",
	} {
		if !strings.Contains(string(buildScript), expected) {
			t.Errorf("Release build script does not contain %q", expected)
		}
	}
}

func TestStagingRolloutContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-staging-overlay.ps1"),
			expected: []string{
				".shieldward/staging",
				"sha256:[0-9a-f]{64}",
				"digest:",
				"rollout.json",
				"No credentials were written",
			},
		},
		{
			path: filepath.Join("scripts", "invoke-staging-rollout.ps1"),
			expected: []string{
				"ExpectedContext",
				"current-context",
				"rollout', 'status",
				"default_deny",
				"IncludeControlPlaneOutageDrill",
				"Sanitized evidence",
			},
		},
		{
			path: filepath.Join("docs", "staging-rollout.md"),
			expected: []string{
				"digest-pinned",
				"ExpectedContext",
				"-IncludeControlPlaneOutageDrill",
				"Roll back by digest",
				"blocked promotion",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Generate digest-pinned staging bundle",
				"new-staging-overlay.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read staging rollout artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("staging rollout artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionPromotionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-promotion-plan.ps1"),
			expected: []string{
				"StagingEvidencePath",
				"ProductionContext must be different",
				"RollbackControlPlaneDigest",
				"integrityDigest",
				"no cluster changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-promotion-plan.ps1"),
			expected: []string{
				"ExpectedProductionContext",
				"current-context",
				"CheckCluster",
				"approved rollback baseline",
				"not traffic-routing enforcement",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-promotion.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-promotion-contract.ps1"),
			expected: []string{
				"invalidApprovalRejected",
				"planTamperingRejected",
				"tamperingRejected",
				"Production promotion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-promotion.md"),
			expected: []string{
				"operator decision gate",
				"existing rollback baseline",
				"-CheckCluster",
				"does not enforce traffic routing",
				"Stop or roll back",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production promotion planning contract",
				"test-production-promotion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production promotion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production promotion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestInitialProductionInstallationContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-initial-production-plan.ps1"),
			expected: []string{
				"StagingEvidencePath",
				"ProductionContext must be different",
				"trafficState = 'disabled'",
				"remove-installation",
				"no cluster changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-initial-production-plan.ps1"),
			expected: []string{
				"ExpectedProductionContext",
				"current-context",
				"initial-empty-baseline",
				"No Secret values were read",
				"not traffic-routing enforcement",
			},
		},
		{
			path: filepath.Join("scripts", "approve-initial-production-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"Traffic remains disabled",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-initial-production-contract.ps1"),
			expected: []string{
				"sameContextRejected",
				"invalidApprovalRejected",
				"trafficTamperingRejected",
				"evidenceTamperingRejected",
				"Initial production installation planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "initial-production-installation.md"),
			expected: []string{
				"operator decision gate",
				"traffic disabled",
				"empty-baseline preflight",
				"not authorize or perform traffic enablement",
				"Abort or remove",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test initial production installation contract",
				"test-initial-production-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read initial production installation artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("initial production installation artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionBaselineAndTrafficContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-baseline-evidence.ps1"),
			expected: []string{
				"TrafficIsolationEvidenceReference",
				"RemovalDrillEvidenceReference",
				"current-context",
				"candidate-ready-traffic-disabled",
				"no cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-baseline-evidence.ps1"),
			expected: []string{
				"ExpectedProductionContext",
				"initialPlanSha256",
				"CheckCluster",
				"externally exposed",
				"does not change or authorize routing",
			},
		},
		{
			path: filepath.Join("scripts", "new-production-traffic-plan.ps1"),
			expected: []string{
				"MaxBaselineAgeMinutes",
				"ValidateRange(1, 10)",
				"disable-traffic-and-remove-installation",
				"Required approval statement",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-traffic-plan.ps1"),
			expected: []string{
				"fresh-traffic-disabled-baseline",
				"canaryPercent",
				"stale",
				"PostActivationEvidence",
				"CheckCluster",
				"does not enforce or change traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-traffic-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-traffic-contract.ps1"),
			expected: []string{
				"invalidApprovalRejected",
				"staleBaselineRejected",
				"trafficTamperingRejected",
				"baselineTamperingRejected",
				"Production baseline and traffic activation planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-baseline-and-traffic.md"),
			expected: []string{
				"read-only",
				"1-10 percent",
				"traffic-disabled baseline",
				"does not authorize expansion",
				"disable traffic first",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production baseline and traffic contract",
				"test-production-traffic-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production baseline and traffic artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production baseline and traffic artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionCanaryAndExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-canary-evidence.ps1"),
			expected: []string{
				"ObservedCanaryPercent",
				"ValidationPurpose = 'PostActivationEvidence'",
				"CheckCluster = $true",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-canary-evidence.ps1"),
			expected: []string{
				"initial-canary-observation",
				"trafficPlanApprovalDigest",
				"expectedOutcome",
				"CheckCluster",
				"does not change or authorize traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "new-production-expansion-plan.ps1"),
			expected: []string{
				"ValidateRange(2, 25)",
				"TargetPercent",
				"passed-canary-evidence",
				"bounded-first-expansion",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-expansion-plan.ps1"),
			expected: []string{
				"maximumInitialExpansionPercent",
				"canary evidence is stale",
				"PostExpansionEvidence",
				"CheckCluster",
				"does not enforce or change traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-expansion-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-expansion-contract.ps1"),
			expected: []string{
				"unknownCanaryRejected",
				"staleEvidenceRejected",
				"fullTrafficTamperingRejected",
				"evidenceTamperingRejected",
				"Production canary evidence and first expansion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-canary-and-expansion.md"),
			expected: []string{
				"read-only",
				"cannot exceed 25 percent",
				"Missing or unknown signals",
				"authorize any later step or full traffic",
				"Disable traffic first",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production canary and expansion contract",
				"test-production-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production canary and expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production canary and expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionProgressiveExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-expansion-evidence.ps1"),
			expected: []string{
				"ObservedTrafficPercent",
				"ValidationPurpose = 'PostExpansionEvidence'",
				"CheckCluster = $true",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-expansion-evidence.ps1"),
			expected: []string{
				"first-expansion-observation",
				"expansionPlanApprovalDigest",
				"expectedOutcome",
				"CheckCluster",
				"does not change or authorize traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "new-production-progressive-plan.ps1"),
			expected: []string{
				"ValidateRange(3, 50)",
				"maximumStepPercentagePoints",
				"passed-first-expansion-evidence",
				"maximum-half-traffic",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-progressive-plan.ps1"),
			expected: []string{
				"maximumTargetPercent",
				"first-expansion evidence is stale",
				"PostExpansionEvidence",
				"CheckCluster",
				"does not enforce or change traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-progressive-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-progressive-contract.ps1"),
			expected: []string{
				"unknownExpansionRejected",
				"staleEvidenceRejected",
				"fullTrafficTamperingRejected",
				"evidenceTamperingRejected",
				"Production first-expansion evidence and progressive planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-progressive-expansion.md"),
			expected: []string{
				"read-only",
				"at most 25 percentage points",
				"cannot exceed 50 percent",
				"Missing or unknown signals",
				"does not authorize full traffic",
				"previous approved cohort",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production progressive expansion contract",
				"test-production-progressive-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production progressive expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production progressive expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionSecondExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-progressive-evidence.ps1"),
			expected: []string{
				"ObservedTrafficPercent",
				"ValidationPurpose = 'PostExpansionEvidence'",
				"CheckCluster = $true",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-progressive-evidence.ps1"),
			expected: []string{
				"progressive-expansion-observation",
				"progressivePlanApprovalDigest",
				"expectedOutcome",
				"CheckCluster",
				"does not change or authorize traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "new-production-second-expansion-plan.ps1"),
			expected: []string{
				"ValidateRange(4, 75)",
				"maximumStepPercentagePoints",
				"passed-progressive-expansion-evidence",
				"maximum-three-quarter-traffic",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-second-expansion-plan.ps1"),
			expected: []string{
				"maximumTargetPercent",
				"progressive evidence is stale",
				"PostExpansionEvidence",
				"CheckCluster",
				"does not enforce or change traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-second-expansion-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-second-expansion-contract.ps1"),
			expected: []string{
				"unknownProgressiveRejected",
				"staleEvidenceRejected",
				"fullTrafficTamperingRejected",
				"evidenceTamperingRejected",
				"Production progressive evidence and second expansion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-second-expansion.md"),
			expected: []string{
				"read-only",
				"at most 25 percentage points",
				"cannot exceed 75 percent",
				"Missing or unknown signals",
				"does not authorize full traffic",
				"previous approved cohort",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production second expansion contract",
				"test-production-second-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production second expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production second expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionFinalExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-second-expansion-evidence.ps1"),
			expected: []string{
				"ValidateRange(4, 75)",
				"second-expansion-observation",
				"ValidationPurpose = 'PostExpansionEvidence'",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-second-expansion-evidence.ps1"),
			expected: []string{
				"second-expansion-observation",
				"secondExpansionPlanApprovalDigest",
				"expectedOutcome",
				"CheckCluster",
				"does not change or authorize traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "new-production-final-expansion-plan.ps1"),
			expected: []string{
				"ValidateRange(76, 100)",
				"Final expansion requires an observed 75% cohort",
				"exact-full-traffic-target",
				"APPROVE FINAL EXPANSION TO 100%",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-final-expansion-plan.ps1"),
			expected: []string{
				"currentPercent -ne 75",
				"targetPercent -ne 100",
				"second expansion evidence is stale",
				"APPROVE FINAL EXPANSION TO 100%",
				"does not enforce or change traffic routing",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-final-expansion-plan.ps1"),
			expected: []string{
				"ApprovalStatement",
				"approvedAtUnixSeconds",
				"approvalDigest",
				"external change system remains authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-final-expansion-contract.ps1"),
			expected: []string{
				"unknownSecondExpansionRejected",
				"failedSecondExpansionRejected",
				"staleEvidenceRejected",
				"nonFullTargetRejected",
				"fullTrafficTamperingRejected",
				"evidenceTamperingRejected",
				"Production second-expansion evidence and final expansion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-final-expansion.md"),
			expected: []string{
				"read-only",
				"exact 75-to-100-percent",
				"Missing or unknown signals",
				"authoritative change system",
				"previous 75 percent cohort",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production final expansion contract",
				"test-production-final-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production final expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production final expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionSteadyStateContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-full-traffic-evidence.ps1"),
			expected: []string{
				"ValidateRange(100, 100)",
				"full-traffic-observation",
				"ValidationPurpose = 'PostExpansionEvidence'",
				"CapacityStatus",
				"SecurityStatus",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-full-traffic-evidence.ps1"),
			expected: []string{
				"full-traffic-observation",
				"observedTrafficPercent -ne 100",
				"expectedOutcome",
				"trafficControllerExternallyEnforced",
				"authoritative external record",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-steady-state-acceptance.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"outcome -ne 'passed'",
				"observedTrafficPercent -ne 100",
				"does not enforce traffic",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-steady-state-contract.ps1"),
			expected: []string{
				"unknownFullTrafficRejected",
				"failedFullTrafficRejected",
				"incompleteEvidenceRejected",
				"staleEvidenceRejected",
				"nonFullTrafficRejected",
				"externalEnforcementRequired",
				"evidenceTamperingRejected",
				"planTamperingRejected",
				"Production full-traffic evidence and steady-state acceptance contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-steady-state.md"),
			expected: []string{
				"read-only",
				"exactly 100 percent traffic",
				"Missing, unknown, failed, stale, tampered, or incomplete evidence",
				"approved final expansion plan proves authorization only",
				"prior 75 percent cohort",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production steady-state acceptance contract",
				"test-production-steady-state-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production steady-state artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production steady-state artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestContinuousProductionAssuranceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-evidence.ps1"),
			expected: []string{
				"ValidateRange(100, 100)",
				"ongoing-production-assurance",
				"ValidationPurpose = 'OngoingAssurance'",
				"reaccept-before-continuing",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-evidence.ps1"),
			expected: []string{
				"ongoing-production-assurance",
				"observedTrafficPercent -ne 100",
				"materialDriftDetected",
				"expectedOutcome",
				"does not change production or replace external monitoring",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"reacceptanceRequired",
				"stale or its next review is overdue",
				"does not authorize drift or change production state",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-contract.ps1"),
			expected: []string{
				"unknownSignalRejected",
				"materialDriftRejected",
				"failedHealthRejected",
				"certificateRiskRejected",
				"incompleteEvidenceRejected",
				"staleEvidenceRejected",
				"decisionMismatchRejected",
				"evidenceTamperingRejected",
				"acceptedBaselineTamperingRejected",
				"Continuous production assurance and drift detection contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance.md"),
			expected: []string{
				"read-only",
				"exactly 100 percent traffic",
				"Unknown, missing, failed, stale, overdue, or tampered evidence",
				"re-acceptance through the applicable production rollout gate",
				"approved external operations system",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test continuous production assurance contract",
				"test-production-assurance-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read continuous production assurance artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("continuous production assurance artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentResponseContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-response-plan.ps1"),
			expected: []string{
				"production-incident-response",
				"failed or unknown assurance evidence",
				"rollback-to-75-and-investigate",
				"explicit-response-action",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-response-plan.ps1"),
			expected: []string{
				"RequiredState",
				"pending incident response plan has exceeded its response deadline",
				"externalIncidentSystemRequired",
				"integrity digest is invalid",
				"read-only and does not authorize or execute production changes",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-response-plan.ps1"),
			expected: []string{
				"ApprovalStatement must exactly match",
				"approvalDigest",
				"external incident and change systems remain authoritative",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-response-contract.ps1"),
			expected: []string{
				"passedEvidenceRejected",
				"actionMismatchRejected",
				"staleEvidenceRejected",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"incorrectApprovalRejected",
				"Production incident response planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-response.md"),
			expected: []string{
				"failed` or `unknown",
				"authoritative incident record",
				"Use the assurance snapshot's `decision.requiredAction`",
				"externally enforced zero traffic",
				"never executes a production change",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production incident response planning contract",
				"test-production-incident-response-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident response artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident response artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentContainmentContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-containment-evidence.ps1"),
			expected: []string{
				"incident-response-containment",
				"deadlineMet",
				"trafficMatchesPlan",
				"escalate-and-verify-containment",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-containment-evidence.ps1"),
			expected: []string{
				"RequiredState Approved",
				"exact 0, 75, or 100 percent traffic boundary",
				"expectedOutcome",
				"integrity digest is invalid",
				"read-only and does not enforce or change production traffic",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-containment-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"containment is not proven",
				"does not authorize recovery or change production state",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-containment-contract.ps1"),
			expected: []string{
				"pendingPlanRejected",
				"holdEvidencePath",
				"rollbackEvidencePath",
				"disableEvidencePath",
				"mismatchedTrafficPath",
				"failedVerificationPath",
				"unknownVerificationPath",
				"Unknown traffic enforcement was incorrectly recorded as externally enforced",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production incident containment evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-containment.md"),
			expected: []string{
				"100, 75, or 0 percent traffic boundary",
				"A plan proves approval",
				"late, mismatched, or tampered evidence fails closed",
				"never continue from the failed artifact",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production incident containment evidence contract",
				"test-production-incident-containment-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident containment artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident containment artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-plan.ps1"),
			expected: []string{
				"production-incident-recovery",
				"bounded-canary-restoration",
				"RecoveryChangeId must identify a separate recovery change record",
				"continue-remediation-and-hold-traffic",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-plan.ps1"),
			expected: []string{
				"RequiredState",
				"canary of 1-10 percent",
				"Failed or unknown recovery readiness must remain blocked",
				"recovery plan integrity digest is invalid",
				"does not change or prove restored production traffic",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-plan.ps1"),
			expected: []string{
				"Only a passed production incident recovery plan may be approved",
				"approvalDigest",
				"external incident and change systems remain authoritative",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-gate.ps1"),
			expected: []string{
				"MaxPlanAgeMinutes",
				"stale, future-dated, or expired",
				"recovery is not authorized",
				"does not change production state or prove traffic restoration",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-contract.ps1"),
			expected: []string{
				"zeroRecoveryPlanPath",
				"rollbackRecoveryPlanPath",
				"holdRecoveryPlanPath",
				"invalidTargetRejected",
				"failedRemediationPlanPath",
				"missingReacceptancePlanPath",
				"unknownTrafficPlanPath",
				"pendingChangePlanPath",
				"recoveryPlanTamperingRejected",
				"containmentTimestampTamperingRejected",
				"containmentTamperingRejected",
				"Production incident recovery planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery.md"),
			expected: []string{
				"containment approval and successful command output do not authorize",
				"0% to",
				"Zero traffic never jumps directly",
				"The gate does not prove restoration",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production incident recovery planning contract",
				"test-production-incident-recovery-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-evidence.ps1"),
			expected: []string{
				"incident-recovery-execution",
				"trafficMatchesPlan",
				"recoveryGateReference",
				"restore-contained-boundary-and-escalate",
				"fullTrafficRestored",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production incident recovery plan no longer matches",
				"recoveryGateReference",
				"recovery execution rollback evidence is inconsistent",
				"recovery evidence integrity digest is invalid",
				"does not authorize further traffic expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"recovery execution is not proven",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-evidence-contract.ps1"),
			expected: []string{
				"zeroEvidencePath",
				"rollbackEvidencePath",
				"holdEvidencePath",
				"pendingPlanRejected",
				"blockedPlanRejected",
				"mismatchedTrafficPath",
				"failedWorkloadPath",
				"unknownTrafficPath",
				"rollbackNotReadyPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production incident recovery execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-evidence.md"),
			expected: []string{
				"Approval proves intent",
				"A zero-traffic recovery remains a 1-10%",
				"A green execution gate proves only the recorded target",
				"target execution as incident closure",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production incident recovery execution evidence contract",
				"test-production-incident-recovery-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-expansion-plan.ps1"),
			expected: []string{
				"incident-recovery-canary-expansion",
				"Recovery re-expansion requires an externally enforced 1-10 percent recovery canary",
				"maximum-twenty-five-percent-traffic",
				"await-independent-recovery-expansion-approval",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-plan.ps1"),
			expected: []string{
				"RequiredState",
				"passed immutable recovery execution evidence no longer matches",
				"Failed or unknown recovery canary observation must remain blocked",
				"recovery expansion plan integrity digest is invalid",
				"does not change or prove expanded production traffic",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-expansion-plan.ps1"),
			expected: []string{
				"Only a passed production recovery expansion plan may be approved",
				"approvalDigest",
				"external incident and change systems remain authoritative",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-gate.ps1"),
			expected: []string{
				"MaxPlanAgeMinutes",
				"stale, future-dated, or expired",
				"hold the recovery canary and preserve evidence",
				"does not change traffic, prove expansion, or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-contract.ps1"),
			expected: []string{
				"fullTrafficEvidencePath",
				"oversized-target",
				"mismatched-observation",
				"degradedPlanPath",
				"unknownPlanPath",
				"pendingChangePlanPath",
				"short-observation",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"Production recovery canary observation and expansion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-expansion.md"),
			expected: []string{
				"1-10 percent recovery canary",
				"no higher than 25 percent",
				"healthy observation does not itself authorize",
				"An approved plan is intent, not execution evidence",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery canary observation and expansion contract",
				"test-production-incident-recovery-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryExpansionEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-expansion-evidence.ps1"),
			expected: []string{
				"incident-recovery-expansion-execution",
				"trafficMatchesPlan",
				"expansionGateReference",
				"observe-recovery-expansion-before-next-step",
				"restore-recovery-canary-and-escalate",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production recovery expansion plan no longer matches",
				"expansionGateReference",
				"recovery expansion rollback evidence is inconsistent",
				"recovery expansion evidence integrity digest is invalid",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"recovery expansion execution is not proven",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-expansion-evidence-contract.ps1"),
			expected: []string{
				"pendingPlanRejected",
				"mismatchedTrafficPath",
				"failedWorkloadPath",
				"unknownTrafficPath",
				"exhaustedBudgetPath",
				"rollbackNotReadyPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production recovery expansion execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-expansion-evidence.md"),
			expected: []string{
				"approved plan proves intent",
				"observed traffic must later equal",
				"Unknown enforcement must never be represented as successful",
				"Another expansion requires a separate observation",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery expansion execution evidence contract",
				"test-production-incident-recovery-expansion-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery expansion evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery expansion evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryProgressiveContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-progressive-plan.ps1"),
			expected: []string{
				"incident-recovery-progressive-expansion",
				"maximum-twenty-five-percentage-point-step",
				"maximum-fifty-percent-traffic",
				"await-independent-recovery-progressive-approval",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-plan.ps1"),
			expected: []string{
				"RequiredState",
				"passed immutable recovery expansion execution evidence no longer matches",
				"restore-previous-recovery-boundary-or-disable",
				"progressive expansion plan integrity digest is invalid",
				"does not change or prove expanded production traffic",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-progressive-plan.ps1"),
			expected: []string{
				"Only a passed production recovery progressive expansion plan may be approved",
				"approvalDigest",
				"external incident and change systems remain authoritative",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-gate.ps1"),
			expected: []string{
				"MaxPlanAgeMinutes",
				"stale, future-dated, or expired",
				"hold the previous recovery boundary and preserve evidence",
				"does not change traffic, prove expansion, or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-contract.ps1"),
			expected: []string{
				"failedEvidencePath",
				"oversized-target",
				"mismatched-observation",
				"degradedPlanPath",
				"unknownPlanPath",
				"pendingChangePlanPath",
				"short-observation",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"Production recovery progressive observation and expansion planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-progressive.md"),
			expected: []string{
				"2-25 percent recovery expansion boundary",
				"increase is capped at 25 percentage points",
				"healthy observation does not itself authorize",
				"An approved plan is intent, not execution evidence",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery progressive observation and expansion contract",
				"test-production-incident-recovery-progressive-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery progressive artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery progressive artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryProgressiveEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-progressive-evidence.ps1"),
			expected: []string{
				"incident-recovery-progressive-execution",
				"trafficMatchesPlan",
				"progressiveGateReference",
				"observe-recovery-progressive-expansion-before-next-step",
				"restore-previous-recovery-boundary-and-escalate",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production recovery progressive plan no longer matches",
				"progressiveGateReference",
				"recovery progressive expansion rollback evidence is inconsistent",
				"recovery progressive evidence integrity digest is invalid",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"progressive expansion execution is not proven",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-progressive-evidence-contract.ps1"),
			expected: []string{
				"pendingPlanRejected",
				"mismatchedTrafficPath",
				"failedWorkloadPath",
				"unknownTrafficPath",
				"exhaustedBudgetPath",
				"rollbackNotReadyPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production recovery progressive expansion execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-progressive-evidence.md"),
			expected: []string{
				"approved plan proves intent",
				"observed traffic must later equal",
				"Unknown enforcement must never be represented as successful",
				"does not authorize another increase",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery progressive expansion execution evidence contract",
				"test-production-incident-recovery-progressive-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery progressive evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery progressive evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoverySecondExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-second-expansion-plan.ps1"),
			expected: []string{
				"incident-recovery-second-expansion",
				"maximum-seventy-five-percent-traffic",
				"await-independent-recovery-second-expansion-approval",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-plan.ps1"),
			expected: []string{
				"test-production-incident-recovery-progressive-evidence.ps1",
				"maximumTargetPercent -ne 75",
				"maxProgressiveEvidenceAgeMinutes",
				"second expansion plan integrity digest is invalid",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-second-expansion-plan.ps1"),
			expected: []string{
				"RequiredState = 'Pending'",
				"ApprovalStatement must exactly match",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-gate.ps1"),
			expected: []string{
				"secondExpansionChange",
				"execute-approved-recovery-second-expansion-externally",
				"does not change traffic, prove expansion, or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-contract.ps1"),
			expected: []string{
				"oversized-target",
				"mismatched-observation",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"Production recovery second expansion observation and planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-second-expansion.md"),
			expected: []string{
				"bounded 50-to-75-percent plan",
				"capped at 25 percentage points",
				"An approved plan is intent",
				"They never route",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery second expansion observation and planning contract",
				"test-production-incident-recovery-second-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery second expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery second expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoverySecondExpansionEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-second-expansion-evidence.ps1"),
			expected: []string{
				"incident-recovery-second-expansion-execution",
				"trafficMatchesPlan",
				"secondExpansionGateReference",
				"observe-recovery-second-expansion-before-next-step",
				"restore-previous-recovery-boundary-and-escalate",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production recovery second expansion plan no longer matches",
				"secondExpansionGateReference",
				"recovery second expansion rollback evidence is inconsistent",
				"recovery second expansion evidence integrity digest is invalid",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"second expansion execution is not proven",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-second-expansion-evidence-contract.ps1"),
			expected: []string{
				"pendingPlanRejected",
				"mismatchedTrafficPath",
				"failedWorkloadPath",
				"unknownTrafficPath",
				"exhaustedBudgetPath",
				"rollbackNotReadyPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production recovery second expansion execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-second-expansion-evidence.md"),
			expected: []string{
				"approved plan proves intent",
				"observed traffic must later equal",
				"Unknown enforcement must never be represented as successful",
				"does not authorize another increase",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery second expansion execution evidence contract",
				"test-production-incident-recovery-second-expansion-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery second expansion evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery second expansion evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryFinalExpansionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-final-expansion-plan.ps1"),
			expected: []string{
				"incident-recovery-final-expansion",
				"exactly-one-hundred-percent-traffic",
				"await-independent-recovery-final-expansion-approval",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-plan.ps1"),
			expected: []string{
				"test-production-incident-recovery-second-expansion-evidence.ps1",
				"currentPercent -ne 75",
				"targetPercent -ne 100",
				"final expansion plan integrity digest is invalid",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-final-expansion-plan.ps1"),
			expected: []string{
				"RequiredState = 'Pending'",
				"ApprovalStatement must exactly match",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-gate.ps1"),
			expected: []string{
				"finalExpansionChange",
				"execute-approved-recovery-final-expansion-externally",
				"does not change traffic, prove expansion, or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-contract.ps1"),
			expected: []string{
				"oversized-target",
				"mismatched-observation",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"Production recovery final expansion observation and planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-final-expansion.md"),
			expected: []string{
				"bounded 75-to-100-percent plan",
				"exactly 100 percent",
				"An approved plan is intent",
				"They never route",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery final expansion observation and planning contract",
				"test-production-incident-recovery-final-expansion-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery final expansion artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery final expansion artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryFinalExpansionEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-final-expansion-evidence.ps1"),
			expected: []string{
				"incident-recovery-final-expansion-execution",
				"trafficMatchesPlan",
				"finalExpansionGateReference",
				"begin-independent-recovery-acceptance-and-incident-closure-review",
				"restore-previous-recovery-boundary-and-escalate",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production recovery final expansion plan no longer matches",
				"finalExpansionGateReference",
				"recovery final expansion rollback evidence is inconsistent",
				"recovery final expansion evidence integrity digest is invalid",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"final expansion execution is not proven",
				"expectedPercent -ne 100",
				"does not authorize further expansion or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-final-expansion-evidence-contract.ps1"),
			expected: []string{
				"pendingPlanRejected",
				"mismatchedTrafficPath",
				"failedWorkloadPath",
				"unknownTrafficPath",
				"exhaustedBudgetPath",
				"rollbackNotReadyPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production recovery final expansion execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-final-expansion-evidence.md"),
			expected: []string{
				"approved plan proves intent",
				"observed traffic must later equal",
				"Unknown enforcement must never be represented as successful",
				"does not itself close the incident",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery final expansion execution evidence contract",
				"test-production-incident-recovery-final-expansion-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery final expansion evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery final expansion evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryClosureContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-closure-plan.ps1"),
			expected: []string{
				"incident-recovery-closure",
				"currentPercent -ne 100",
				"trafficMutationPercentagePoints = 0",
				"ReacceptanceStatus",
				"rollbackTargetPercent",
				"APPROVE RECOVERY INCIDENT CLOSURE",
				"No cluster or traffic changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-plan.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"requiredHoldPercent -ne 100",
				"rollback.targetPercent -ne 75",
				"observation.reacceptance",
				"externalIncidentSystemRequired",
				"does not change traffic or close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-incident-recovery-closure-plan.ps1"),
			expected: []string{
				"RequiredState = 'Pending'",
				"ApprovalStatement must exactly match",
				"close the recovery incident through the authoritative system after independent review",
				"this script does not close the incident",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-gate.ps1"),
			expected: []string{
				"MaxPlanAgeMinutes",
				"observation.reacceptance -ne 'passed'",
				"trafficMutationPercentagePoints -ne 0",
				"rollback.targetPercent -ne 75",
				"This gate is read-only",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-contract.ps1"),
			expected: []string{
				"failed-reacceptance",
				"pending-change",
				"planTamperingRejected",
				"evidenceTamperingRejected",
				"Production recovery incident closure observation and planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-closure.md"),
			expected: []string{
				"holds that boundary",
				"independent production re-acceptance",
				"rollback-to-75 procedure ready",
				"does not close anything or change traffic",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery incident closure observation and planning contract",
				"test-production-incident-recovery-closure-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery closure artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery closure artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionIncidentRecoveryClosureEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-incident-recovery-closure-evidence.ps1"),
			expected: []string{
				"incident-recovery-closure-execution",
				"closurePlanApprovalDigest",
				"IncidentClosureStatus",
				"trafficMatchesPlan",
				"begin-post-incident-assurance-and-retrospective",
				"No cluster, traffic, change-record, or incident-system changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-evidence.ps1"),
			expected: []string{
				"RequiredState = 'Approved'",
				"approved production recovery closure plan no longer matches",
				"authoritativeExternalSystemRequired",
				"treat-incident-as-open-and-collect-closure-evidence",
				"incident-closure evidence integrity digest is invalid",
				"does not close or reopen the incident, change traffic, or discard rollback",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"closure.incidentStatus -ne 'closed'",
				"rollback.targetPercent -ne 75",
				"proves only the recorded external closure",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-incident-recovery-closure-evidence-contract.ps1"),
			expected: []string{
				"pendingPlan",
				"openIncidentPath",
				"unknownClosurePath",
				"missingRollbackPath",
				"incompleteAuditPath",
				"evidenceTamperingRejected",
				"approvedPlanTamperingRejected",
				"Production recovery incident closure execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-incident-recovery-closure-evidence.md"),
			expected: []string{
				"approved plan proves intent",
				"Unknown closure state must be treated as an open incident",
				"repository intentionally provides no command",
				"does not perform closure",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production recovery incident closure execution evidence contract",
				"test-production-incident-recovery-closure-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production incident recovery closure evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production incident recovery closure evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionPostIncidentAssuranceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-post-incident-assurance-evidence.ps1"),
			expected: []string{
				"post-incident-assurance-and-retrospective",
				"closureEvidenceIntegrityDigest",
				"MinimumAssuranceWindowHours",
				"trafficMatchesClosure",
				"resume-continuous-production-assurance",
				"No cluster, traffic, incident, change-record, or retrospective-system changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-post-incident-assurance-evidence.ps1"),
			expected: []string{
				"approved production recovery closure evidence no longer matches",
				"authoritativeExternalSystemRequired",
				"treat-assurance-as-incomplete-and-collect-evidence",
				"post-incident assurance evidence integrity digest is invalid",
				"does not change traffic, incidents, external records, or rollback state",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-post-incident-assurance-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"incident.status -ne 'closed'",
				"rollback.targetPercent -ne 75",
				"proves only recorded assurance and retrospective evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-post-incident-assurance-contract.ps1"),
			expected: []string{
				"reopenedIncidentPath",
				"unknownSecurityPath",
				"incompleteRetrospectivePath",
				"missingRollbackPath",
				"evidenceTamperingRejected",
				"closureEvidenceTamperingRejected",
				"Production post-incident assurance and retrospective evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-post-incident-assurance.md"),
			expected: []string{
				"Unknown assurance or retrospective state is not success",
				"repository intentionally provides no command",
				"Never edit generated JSON",
				"does not guarantee future health",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production post-incident assurance and retrospective evidence contract",
				"test-production-post-incident-assurance-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production post-incident assurance artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production post-incident assurance artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceResumptionContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-resumption-evidence.ps1"),
			expected: []string{
				"continuous-production-assurance-resumption",
				"postIncidentEvidenceIntegrityDigest",
				"AssuranceScheduleStatus",
				"trafficMatchesPostIncident",
				"continue-scheduled-production-assurance",
				"No scheduler, cluster, traffic, incident, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-resumption-evidence.ps1"),
			expected: []string{
				"passed post-incident assurance evidence no longer matches",
				"reaccept-before-continuing",
				"investigate-and-refresh-evidence",
				"production assurance resumption evidence integrity digest is invalid",
				"does not activate schedulers, change production, or remove rollback",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-resumption-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale, future-dated, or already overdue",
				"schedule.status -ne 'active'",
				"rollback.targetPercent -ne 75",
				"proves only recorded resumption evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-resumption-contract.ps1"),
			expected: []string{
				"inactiveSchedulePath",
				"unknownMonitoringPath",
				"driftEvidencePath",
				"securityIncidentPath",
				"missingRollbackPath",
				"evidenceTamperingRejected",
				"postIncidentTamperingRejected",
				"Continuous production assurance resumption evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-resumption.md"),
			expected: []string{
				"active scheduler is not proof",
				"repository intentionally provides no command",
				"Never edit generated JSON",
				"does not activate a scheduler",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test continuous production assurance resumption evidence contract",
				"test-production-assurance-resumption-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance resumption artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance resumption artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceContinuityContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-continuity-evidence.ps1"),
			expected: []string{
				"scheduled-production-assurance-continuity",
				"resumptionEvidenceIntegrityDigest",
				"CompletionGraceMinutes",
				"reviewOnTime",
				"escalate-missed-assurance-review",
				"No scheduler, cluster, traffic, incident, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-continuity-evidence.ps1"),
			expected: []string{
				"passed production assurance resumption evidence no longer matches",
				"expectedDueAt",
				"escalate-missed-assurance-review",
				"production assurance continuity evidence integrity digest is invalid",
				"does not schedule reviews, change production, or remove rollback",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-continuity-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale, future-dated, or overdue",
				"review.executionStatus -ne 'completed'",
				"rollback.targetPercent -ne 75",
				"proves only recorded continuity evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-continuity-contract.ps1"),
			expected: []string{
				"lateReviewPath",
				"missedReviewPath",
				"unknownReviewPath",
				"inactiveSchedulePath",
				"driftEvidencePath",
				"missingRollbackPath",
				"evidenceTamperingRejected",
				"resumptionTamperingRejected",
				"Scheduled production assurance continuity evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-continuity.md"),
			expected: []string{
				"A running scheduler does not prove that a review completed",
				"repository intentionally provides no command",
				"Never edit generated JSON",
				"does not schedule reviews",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test scheduled production assurance continuity evidence contract",
				"test-production-assurance-continuity-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance continuity artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance continuity artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRecurringContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-recurring-evidence.ps1"),
			expected: []string{
				"recurring-production-assurance-continuity",
				"previousContinuityEvidenceIntegrityDigest",
				"reviewSequence = [int]$previous.review.sequence + 1",
				"escalate-missed-assurance-review",
				"No scheduler, cluster, traffic, incident, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-recurring-evidence.ps1"),
			expected: []string{
				"exact passed previous continuity evidence no longer matches",
				"expectedSequence",
				"continuityLinkValid",
				"recurring production assurance evidence integrity digest is invalid",
				"does not schedule reviews, change production, or remove rollback",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-recurring-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale, future-dated, or overdue",
				"review.sequence -lt 2",
				"rollback.targetPercent -ne 75",
				"recorded recurring review chain",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-recurring-contract.ps1"),
			expected: []string{
				"passed-sequence-2",
				"passed-sequence-3",
				"failed-previous-link",
				"evidenceTamperingRejected",
				"previousTamperingRejected",
				"Recurring production assurance continuity evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-recurring.md"),
			expected: []string{
				"review sequence 2 and every later",
				"cannot skip",
				"Never edit generated JSON",
				"schedule the next review",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test recurring production assurance continuity evidence contract",
				"test-production-assurance-recurring-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read recurring production assurance artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("recurring production assurance artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceChainAuditContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-chain-audit-evidence.ps1"),
			expected: []string{
				"production-assurance-chain-audit",
				"review chain contains a cycle",
				"chainEntryCount",
				"restore-evidence-and-investigate",
				"No scheduler, cluster, traffic, incident, evidence-retention, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-chain-audit-evidence.ps1"),
			expected: []string{
				"exact passed production assurance chain head no longer matches",
				"recurring assurance chain contains a sequence gap",
				"chain inventory, digest, or entry count is invalid",
				"chain audit evidence integrity digest is invalid",
				"does not schedule reviews, retain evidence, change production, or remove rollback",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-chain-audit-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale or future-dated",
				"chain.headSequence -lt 2",
				"audit.chainInventoryStatus -ne 'complete'",
				"recorded audit checkpoint",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-chain-audit-contract.ps1"),
			expected: []string{
				"passed-sequence-3",
				"invalid-head",
				"incomplete-inventory",
				"auditTamperingRejected",
				"interiorTamperingRejected",
				"Production assurance chain audit evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-chain-audit.md"),
			expected: []string{
				"inventories the entire",
				"no gap or cycle",
				"Never edit generated JSON",
				"does not schedule a",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance chain audit evidence contract",
				"test-production-assurance-chain-audit-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance chain audit artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance chain audit artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceEvidenceCustodyContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-custody-evidence.ps1"),
			expected: []string{
				"production-assurance-evidence-custody",
				"ArchivedAuditSha256",
				"retentionMeetsPolicy",
				"quarantine-and-rebuild-archive",
				"No archive upload, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-evidence.ps1"),
			expected: []string{
				"exact passed production assurance chain audit no longer matches",
				"archived checksum, chain digest, or retention decision is inconsistent",
				"restrict-access-and-investigate",
				"evidence custody integrity digest is invalid",
				"does not upload, retain, delete, restore, or change production evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"retentionUntil -le",
				"outside its retention window",
				"archive.objectLockStatus -ne 'enforced'",
				"recorded external custody evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-contract.ps1"),
			expected: []string{
				"checksumMismatchPath",
				"chainDigestMismatchPath",
				"shortRetentionPath",
				"custodyTamperingRejected",
				"auditTamperingRejected",
				"Production assurance evidence custody contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-evidence-custody.md"),
			expected: []string{
				"Archive registration is not enforcement",
				"repository does not upload",
				"Never edit generated JSON",
				"proves only recorded external custody evidence",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance evidence custody contract",
				"test-production-assurance-custody-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance evidence custody artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance evidence custody artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestScheduledProductionAssuranceCustodyReviewContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-custody-review-evidence.ps1"),
			expected: []string{
				"scheduled-production-assurance-custody-review",
				"ScheduledReviewDueAtUtc",
				"retentionRemainingMeetsPolicy",
				"renew-retention-before-continuing",
				"No archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-review-evidence.ps1"),
			expected: []string{
				"exact passed production assurance evidence custody no longer matches",
				"custody review schedule or retention decision is inconsistent",
				"escalate-missed-custody-review",
				"custody review integrity digest is invalid",
				"does not schedule reviews, alter archives, change production, or remove evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-review-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"nextReviewDueAt -le",
				"outside its retention schedule",
				"controls.archiveAvailability -ne 'available'",
				"recorded custody review",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-review-contract.ps1"),
			expected: []string{
				"late-review",
				"missing-archive",
				"outside-retention",
				"reviewTamperingRejected",
				"custodyTamperingRejected",
				"Scheduled production assurance custody review contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-custody-review.md"),
			expected: []string{
				"first scheduled review",
				"scheduled review record is not enforcement",
				"Never edit generated JSON",
				"proves only the recorded custody review",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test scheduled production assurance custody review contract",
				"test-production-assurance-custody-review-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read scheduled production assurance custody review artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("scheduled production assurance custody review artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestRecurringProductionAssuranceCustodyReviewContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-custody-recurring-evidence.ps1"),
			expected: []string{
				"recurring-production-assurance-custody-review",
				"PreviousCustodyReviewEvidencePath",
				"reviewSequence = $previousSequence + 1",
				"renew-retention-before-continuing",
				"No scheduler, archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-recurring-evidence.ps1"),
			expected: []string{
				"exact passed previous production assurance custody review no longer matches",
				"root production assurance custody boundary changed",
				"recurring custody review sequence, timing, retention, or freshness boundary is invalid",
				"recurring production assurance custody review integrity digest is invalid",
				"does not schedule reviews, alter archives, change production, or remove evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-recurring-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"review.sequence -lt 2",
				"outside its retention schedule",
				"previousCustodyReviewEvidence.custodyContinuityProven",
				"recorded recurring custody-review chain",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-recurring-contract.ps1"),
			expected: []string{
				"passed-sequence-2",
				"passed-sequence-4",
				"retention-renewal",
				"reviewTamperingRejected",
				"previousTamperingRejected",
				"Recurring production assurance custody review contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-custody-recurring.md"),
			expected: []string{
				"sequence 2 and every later",
				"Registration is not enforcement",
				"Never edit generated JSON",
				"proves only the recorded recurring custody-review chain",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test recurring production assurance custody review contract",
				"test-production-assurance-custody-recurring-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read recurring production assurance custody review artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("recurring production assurance custody review artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceCustodyChainAuditContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-custody-chain-audit-evidence.ps1"),
			expected: []string{
				"production-assurance-custody-chain-audit",
				"custody-review chain contains a cycle",
				"root custody identity or retention boundary",
				"repair-archive-and-repeat-restore-test",
				"No scheduler, archive, custody, retention, access, restore, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-chain-audit-evidence.ps1"),
			expected: []string{
				"exact passed production assurance custody chain head no longer matches",
				"custody-review chain contains a sequence gap",
				"custody chain inventory, root, digest, or entry count is invalid",
				"custody chain-audit evidence integrity digest is invalid",
				"does not schedule reviews, alter archives, change production, or remove evidence",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-chain-audit-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"stale, future-dated, or outside retention",
				"chain.headSequence -lt 2",
				"audit.restoreAuditStatus -ne 'passed'",
				"recorded audit checkpoint",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-custody-chain-audit-contract.ps1"),
			expected: []string{
				"passed-sequence-3",
				"invalid-root",
				"failed-restore-audit",
				"auditTamperingRejected",
				"interiorTamperingRejected",
				"Production assurance custody chain-audit evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-custody-chain-audit.md"),
			expected: []string{
				"inventories the entire custody-review chain",
				"no gap or cycle",
				"Registration is not enforcement",
				"Never edit generated JSON",
				"does not schedule a review",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance custody chain audit contract",
				"test-production-assurance-custody-chain-audit-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance custody chain-audit artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance custody chain-audit artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRetentionRenewalPlanningContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-retention-renewal-plan.ps1"),
			expected: []string{
				"production-assurance-retention-renewal-plan",
				"failed custody chain-audit evidence",
				"minimumRequestedRetention",
				"obtain-independent-retention-renewal-approval",
				"No archive, object-lock, retention, access, restore, scheduler, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-plan.ps1"),
			expected: []string{
				"exact failed custody chain-audit trigger no longer matches",
				"changed the root custody or review-chain identity",
				"retention-renewal duration, review coverage, or timing boundary is invalid",
				"retention-renewal plan integrity digest is invalid",
				"does not renew retention, alter archives, restore evidence, or change production",
			},
		},
		{
			path: filepath.Join("scripts", "approve-production-assurance-retention-renewal-plan.ps1"),
			expected: []string{
				"ApprovedBy must exactly match",
				"ApprovalStatement must exactly match",
				"execute-approved-external-retention-renewal",
				"external change and archive systems remain authoritative",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-gate.ps1"),
			expected: []string{
				"MaxPlanAgeMinutes",
				"stale, future-dated, expired, or insufficient",
				"externalExecutionAuthorized -ne $true",
				"does not prove retention was renewed",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-contract.ps1"),
			expected: []string{
				"invalid-trigger",
				"short-extension",
				"planTamperingRejected",
				"triggerTamperingRejected",
				"Production assurance retention-renewal planning contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-retention-renewal.md"),
			expected: []string{
				"local plan is not proof",
				"Registration is not enforcement",
				"Never edit generated JSON",
				"Execute externally and preserve evidence",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance retention renewal planning contract",
				"test-production-assurance-retention-renewal-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance retention-renewal artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance retention-renewal artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRetentionRenewalEvidenceContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-retention-renewal-evidence.ps1"),
			expected: []string{
				"production-assurance-retention-renewal-evidence",
				"execution must follow approval",
				"observedMeetsApprovedBoundary",
				"establish-renewed-custody-review-baseline",
				"No archive, object-lock, retention, access, restore, scheduler, cluster, traffic, or rollback changes were made",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-evidence.ps1"),
			expected: []string{
				"exact approved retention-renewal plan no longer matches",
				"changed the original custody or review-chain identity",
				"retention-renewal execution, duration, or freshness boundary is invalid",
				"retention-renewal evidence integrity digest is invalid",
				"does not renew retention, alter archives, restore evidence, or change production",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-evidence-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"overdue for the next custody review",
				"decision.retentionRenewalProven -ne $true",
				"does not change retention, reset custody lineage, or change production",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-retention-renewal-evidence-contract.ps1"),
			expected: []string{
				"failed-change",
				"insufficient-retention",
				"pending-plan",
				"evidenceTamperingRejected",
				"planTamperingRejected",
				"Production assurance retention-renewal execution evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-retention-renewal-evidence.md"),
			expected: []string{
				"approved plan is not execution evidence",
				"Unknown states fail closed",
				"Never edit generated JSON",
				"Establish a renewed review baseline",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance retention renewal evidence contract",
				"test-production-assurance-retention-renewal-evidence-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance retention-renewal evidence artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance retention-renewal evidence artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRenewedCustodyBaselineContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-renewed-custody-baseline.ps1"),
			expected: []string{
				"production-assurance-renewed-custody-baseline",
				"priorReviewChainDigest",
				"resume-scheduled-custody-reviews",
				"No review was scheduled, no prior evidence was rewritten",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-baseline.ps1"),
			expected: []string{
				"exact passed retention-renewal evidence no longer matches",
				"rewrote the original custody or prior review-chain identity",
				"baseline timing, sequence, or retention boundary is invalid",
				"baseline integrity digest is invalid",
				"does not schedule reviews, rewrite evidence, or change archives",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-baseline-gate.ps1"),
			expected: []string{
				"MaxBaselineAgeMinutes",
				"overdue for review",
				"decision.priorReviewChainPreserved -ne $true",
				"authorizes only resuming the existing review process",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-baseline-contract.ps1"),
			expected: []string{
				"failed-renewal",
				"early-baseline",
				"baselineTamperingRejected",
				"renewalTamperingRejected",
				"Production assurance renewed custody-review baseline contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-renewed-custody-baseline.md"),
			expected: []string{
				"Passing renewal evidence is not permission to rewrite history",
				"Never edit generated JSON",
				"Resume without resetting history",
				"resume-scheduled-custody-reviews",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance renewed custody baseline contract",
				"test-production-assurance-renewed-custody-baseline-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance renewed custody baseline artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance renewed custody baseline artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRenewedCustodyReviewContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-renewed-custody-review-evidence.ps1"),
			expected: []string{
				"renewed-production-assurance-custody-review",
				"exact passed Chapter 61 baseline",
				"reviewLinkDigest",
				"continue-renewed-custody-reviews",
				"No review was scheduled and no archive",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-review-evidence.ps1"),
			expected: []string{
				"exact passed renewed custody-review baseline no longer matches",
				"rewrote the original custody or prior review-chain lineage",
				"timing, sequence, retention, or freshness boundary is invalid",
				"renewed custody-review evidence integrity digest is invalid",
				"does not schedule reviews, alter archives, change production",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-review-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"overdue for its next review",
				"decision.custodyContinuityProven -ne $true",
				"proves only the recorded review",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-review-contract.ps1"),
			expected: []string{
				"late-review",
				"missing-archive",
				"outside-retention",
				"evidenceTamperingRejected",
				"baselineTamperingRejected",
				"Production assurance renewed custody-review evidence contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-renewed-custody-review.md"),
			expected: []string{
				"A renewed baseline is not a completed review",
				"Unknown states fail closed",
				"Never edit generated JSON",
				"Continue the renewed chain",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test production assurance renewed custody review contract",
				"test-production-assurance-renewed-custody-review-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read production assurance renewed custody-review artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("production assurance renewed custody-review artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestProductionAssuranceRecurringRenewedCustodyReviewContracts(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	tests := []struct {
		path     string
		expected []string
	}{
		{
			path: filepath.Join("scripts", "new-production-assurance-renewed-custody-recurring-evidence.ps1"),
			expected: []string{
				"recurring-renewed-production-assurance-custody-review",
				"exact passed previous review evidence",
				"previousReviewEvidenceSha256",
				"continue-renewed-custody-reviews",
				"No scheduler, archive, object-lock, retention",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-recurring-evidence.ps1"),
			expected: []string{
				"exact previous renewed custody-review evidence no longer matches",
				"changed the production identity or inherited custody lineage",
				"timing, sequence, retention, or freshness boundary is invalid",
				"recurring production assurance renewed custody-review integrity digest is invalid",
				"does not schedule reviews, alter archives, change production",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-recurring-gate.ps1"),
			expected: []string{
				"MaxEvidenceAgeMinutes",
				"decision.predecessorLinkValid -ne $true",
				"do not continue the review chain",
				"proves only the recorded review",
			},
		},
		{
			path: filepath.Join("scripts", "test-production-assurance-renewed-custody-recurring-contract.ps1"),
			expected: []string{
				"passed-second",
				"failed-predecessor",
				"previousTamperingRejected",
				"evidenceTamperingRejected",
				"Recurring production assurance renewed custody-review contract passed",
			},
		},
		{
			path: filepath.Join("docs", "production-assurance-renewed-custody-recurring.md"),
			expected: []string{
				"exact passed Chapter 62 review",
				"Unknown states fail closed",
				"Never edit generated JSON",
				"continue from the exact latest passed artifact",
			},
		},
		{
			path: filepath.Join(".github", "workflows", "ci.yml"),
			expected: []string{
				"Test recurring production assurance renewed custody review contract",
				"test-production-assurance-renewed-custody-recurring-contract.ps1",
			},
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, test.path))
			if err != nil {
				t.Fatalf("read recurring production assurance renewed custody-review artifact: %v", err)
			}
			for _, expected := range test.expected {
				if !strings.Contains(string(contents), expected) {
					t.Errorf("recurring production assurance renewed custody-review artifact does not contain %q", expected)
				}
			}
		})
	}
}

func TestContinuousIntegrationBuildsReleaseCandidate(t *testing.T) {
	path := filepath.Join("..", "..", ".github", "workflows", "ci.yml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read Continuous Integration workflow: %v", err)
	}

	text := string(contents)
	for _, expected := range []string{
		"release-candidate:",
		"build-release-assets.sh",
		"shieldward-source.spdx.json",
		"verify-release-assets.ps1",
	} {
		if !strings.Contains(text, expected) {
			t.Errorf("Continuous Integration workflow does not contain %q", expected)
		}
	}
}

func TestProductionReleaseDocumentsExist(t *testing.T) {
	repositoryRoot := filepath.Join("..", "..")
	for _, relativePath := range []string{
		"README.md",
		"CHANGELOG.md",
		filepath.Join("docs", "production-acceptance.md"),
		filepath.Join("docs", "failure-drills.md"),
		filepath.Join("docs", "release-runbook.md"),
		filepath.Join("docs", "staging-rollout.md"),
		filepath.Join("docs", "production-promotion.md"),
		filepath.Join("docs", "initial-production-installation.md"),
		filepath.Join("docs", "production-baseline-and-traffic.md"),
		filepath.Join("docs", "production-canary-and-expansion.md"),
		filepath.Join("docs", "production-progressive-expansion.md"),
		filepath.Join("docs", "production-second-expansion.md"),
		filepath.Join("docs", "production-final-expansion.md"),
		filepath.Join("docs", "production-steady-state.md"),
		filepath.Join("docs", "production-assurance.md"),
		filepath.Join("docs", "production-incident-response.md"),
		filepath.Join("docs", "production-incident-containment.md"),
		filepath.Join("docs", "production-incident-recovery.md"),
		filepath.Join("docs", "production-incident-recovery-evidence.md"),
	} {
		t.Run(relativePath, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot, relativePath))
			if err != nil {
				t.Fatalf("read release document: %v", err)
			}
			if len(bytes.TrimSpace(contents)) == 0 {
				t.Fatal("release document is empty")
			}
		})
	}
}

func TestComposeServicesUseRuntimeHardening(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "..", "compose.yaml"))
	if err != nil {
		t.Fatalf("read compose file: %v", err)
	}

	var compose struct {
		Services map[string]struct {
			ReadOnly     bool     `yaml:"read_only"`
			Capabilities []string `yaml:"cap_drop"`
			SecurityOpt  []string `yaml:"security_opt"`
			Ports        []string `yaml:"ports"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(contents, &compose); err != nil {
		t.Fatalf("decode compose file: %v", err)
	}

	for _, serviceName := range []string{"control-plane", "edge"} {
		service, exists := compose.Services[serviceName]
		if !exists {
			t.Errorf("compose service %q is missing", serviceName)
			continue
		}
		if !service.ReadOnly {
			t.Errorf("compose service %q root filesystem is writable", serviceName)
		}
		if !contains(service.Capabilities, "ALL") {
			t.Errorf("compose service %q does not drop all capabilities", serviceName)
		}
		if !contains(service.SecurityOpt, "no-new-privileges:true") {
			t.Errorf("compose service %q allows new privileges", serviceName)
		}
		if serviceName == "control-plane" && len(service.Ports) != 0 {
			t.Errorf("compose control plane publishes host ports: %v", service.Ports)
		}
	}
}

func TestFinalImagesSelectNonRootUsers(t *testing.T) {
	tests := []struct {
		path          string
		expectedUser  string
		expectedFinal string
	}{
		{
			path:          "control-plane.Dockerfile",
			expectedUser:  "USER 65532:65532",
			expectedFinal: "FROM scratch AS runtime",
		},
		{
			path:          "edge.Dockerfile",
			expectedUser:  "USER 1000:1000",
			expectedFinal: "@sha256:",
		},
	}

	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(
				"..",
				"..",
				"deploy",
				"docker",
				test.path,
			))
			if err != nil {
				t.Fatalf("read Dockerfile: %v", err)
			}

			text := string(contents)
			for _, expected := range []string{
				test.expectedUser,
				test.expectedFinal,
				"HEALTHCHECK",
			} {
				if !strings.Contains(text, expected) {
					t.Errorf("Dockerfile does not contain %q", expected)
				}
			}

			if test.path == "edge.Dockerfile" {
				for _, expected := range []string{
					"apk upgrade --no-cache",
					"/usr/local/lib/node_modules/npm",
				} {
					if !strings.Contains(text, expected) {
						t.Errorf("Dockerfile does not contain %q", expected)
					}
				}
			}
		})
	}
}

func assertYAMLDocuments(t *testing.T, path string, kubernetes bool) {
	t.Helper()

	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	decoder := yaml.NewDecoder(bytes.NewReader(contents))
	for documentNumber := 1; ; documentNumber++ {
		var document map[string]any
		err := decoder.Decode(&document)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("decode %s document %d: %v", path, documentNumber, err)
		}
		if len(document) == 0 {
			continue
		}

		if kubernetes {
			if _, exists := document["apiVersion"]; !exists {
				t.Errorf("%s document %d has no apiVersion", path, documentNumber)
			}
			if kind, exists := document["kind"]; !exists || fmt.Sprint(kind) == "" {
				t.Errorf("%s document %d has no kind", path, documentNumber)
			}
		}
	}
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func assertPathExists(t *testing.T, directory, path string) {
	t.Helper()

	if _, err := os.Stat(filepath.Join(directory, path)); err != nil {
		t.Errorf("kustomization path %q: %v", path, err)
	}
}
