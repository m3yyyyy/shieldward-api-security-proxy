# CI and release security

ShieldWard uses four GitHub Actions workflows. Every third-party action is
pinned to a full commit SHA, and Dependabot proposes updates to those pins.

The `Containers` workflow builds and scans the hardened images,
smoke-tests the TLS Compose topology, and publishes multi-platform images for
semantic-version tags.

## Continuous integration

The `Continuous integration` workflow runs on pushes and pull requests targeting
`main`. It checks repository policy, tests and vets Go on Linux and Windows, runs
the Go race detector on Linux, and tests, type-checks, and builds Edge on Linux
and Windows.
The Linux-only distributed-rate-limit job also exercises two independent Edge
clients against an isolated, digest-pinned Redis service.
The Linux `Release candidate` job builds the complete versioned bundle, creates
an SPDX SBOM and checksums, and verifies the artifact contract before a tag can
publish it.

After the first successful pull-request run, configure a branch ruleset for
`main` and require the CI jobs before merging. Also require pull requests and
prevent force pushes or branch deletion. Keep workflow permissions read-only by
default.

## Security automation

The `Security` workflow runs on pushes, pull requests, a weekly schedule, and
manual dispatch. It runs `govulncheck`, `npm audit`, the repository policy
scanner, dependency review, and CodeQL.

Dependency review, CodeQL uploads, and artifact attestations are enabled by the
workflow for public repositories. GitHub plan support for private repositories
varies; private Enterprise Cloud repositories can remove the public-repository
conditions after GitHub Advanced Security and attestations are enabled.

Do not enable CodeQL default setup while the checked-in advanced CodeQL workflow
is active. In repository settings, separately enable the dependency graph,
Dependabot alerts, secret scanning, and push protection where the plan supports
them. These repository settings cannot be enabled by the workflow itself.

Run the local policy check from the repository root before committing:

```powershell
pwsh -NoProfile -File .\scripts\check-repository.ps1
```

This check rejects tracked local state, common private-key paths, recognizable
credential formats, unpinned Actions, checkout steps that retain credentials,
and `pull_request_target` workflows. It supplements GitHub secret scanning; it
does not replace it.

## Creating a release

Release only a clean commit that has passed the required checks. Create and push
a semantic-version tag. Follow `docs/release-runbook.md`; its release-readiness
gate checks that package metadata, workflows, and the requested version agree.

For the first release:

```powershell
git status --short
git tag -a v1.0.0 -m "ShieldWard v1.0.0"
git push origin v1.0.0
```

Use the next unused version instead of `v1.0.0`. A signed tag is preferable when
a signing identity is configured. The tag starts the `Release` workflow; do not
manually upload replacement files to an existing release.

The workflow reruns verification and publishes:

- Linux AMD64 and ARM64 control-plane binaries
- Windows AMD64 and ARM64 control-plane binaries
- a deterministic Edge archive
- an SPDX JSON software bill of materials (SBOM)
- `SHA256SUMS`
- build-provenance and SBOM attestations when GitHub supports them

The `Containers` workflow also publishes versioned control-plane and Edge images
to GitHub Container Registry. The images carry OCI provenance and SBOMs and are
tagged with both the release version and source commit.

Go binaries are built without CGO, local paths, or a random Go build ID. The Edge
archive has sorted entries, normalized ownership, and a fixed timestamp.

## Verifying a downloaded release

From the folder containing the downloaded files, compare a file with its recorded
SHA-256 hash:

```powershell
$file = 'shieldwardd-windows-amd64.exe'
$expected = ((Select-String -Path .\SHA256SUMS -Pattern "  $([regex]::Escape($file))$").Line -split '\s+')[0]
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath ".\$file").Hash.ToLowerInvariant()
$actual -eq $expected
```

The final output must be `True`. For releases with GitHub attestations, also use
GitHub CLI verification:

```powershell
gh attestation verify .\shieldwardd-windows-amd64.exe --repo m3yyyyy/shieldward-api-security-proxy
```

Inspect the SBOM before deployment and keep the release assets together with
their checksum file. `scripts/verify-release-assets.ps1` verifies the exact
inventory, every checksum, SPDX metadata, safe Edge archive paths, archived
package version, and the native control-plane binary version. On Linux, make a
downloaded binary executable with `chmod +x` only after verification.
