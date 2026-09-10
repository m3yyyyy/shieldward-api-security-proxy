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
