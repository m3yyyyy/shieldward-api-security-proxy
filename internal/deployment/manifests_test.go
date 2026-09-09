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
		"--sort=name",
		"gzip -n",
	} {
		if !strings.Contains(string(buildScript), expected) {
			t.Errorf("Release build script does not contain %q", expected)
		}
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
