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
