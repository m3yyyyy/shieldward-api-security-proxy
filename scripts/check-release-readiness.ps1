[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$RequireClean,
    [switch]$RequireTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$packagePath = Join-Path $repoRoot 'edge/package.json'
$packageLockPath = Join-Path $repoRoot 'edge/package-lock.json'
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$containersWorkflowPath = Join-Path $repoRoot '.github/workflows/containers.yml'
$continuousIntegrationPath = Join-Path $repoRoot '.github/workflows/ci.yml'
$releaseBuildScriptPath = Join-Path $repoRoot 'scripts/build-release-assets.sh'

$package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
$packageLock = Get-Content -Raw -LiteralPath $packageLockPath | ConvertFrom-Json -AsHashtable
$packageLockRoot = $packageLock['packages']['']

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]$package.version
}

$semanticVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($Version -notmatch $semanticVersionPattern) {
    throw "Release version '$Version' is not a supported semantic version."
}

foreach ($metadata in @(
    [pscustomobject]@{ Name = 'edge/package.json'; Value = [string]$package.version }
    [pscustomobject]@{ Name = 'edge/package-lock.json'; Value = [string]$packageLock['version'] }
    [pscustomobject]@{ Name = 'edge/package-lock.json root package'; Value = [string]$packageLockRoot['version'] }
)) {
    if ($metadata.Value -ne $Version) {
        throw "$($metadata.Name) reports version '$($metadata.Value)'; expected '$Version'."
    }
}

$releaseWorkflow = [System.IO.File]::ReadAllText($releaseWorkflowPath)
foreach ($requiredText in @(
    'check-release-readiness.ps1'
    'build-release-assets.sh'
    'verify-release-assets.ps1'
    'gh release create'
)) {
    if (-not $releaseWorkflow.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "Release workflow is missing required contract '$requiredText'."
    }
}

$releaseBuildScript = [System.IO.File]::ReadAllText($releaseBuildScriptPath)
foreach ($requiredText in @(
    '-X main.version=${version}'
    '--create --file=-'
    '--sort=name'
    "gzip -n"
)) {
    if (-not $releaseBuildScript.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "Release build script is missing required contract '$requiredText'."
    }
}

$continuousIntegration = [System.IO.File]::ReadAllText($continuousIntegrationPath)
foreach ($requiredText in @(
    'release-candidate:'
    'build-release-assets.sh'
    'verify-release-assets.ps1'
    'test-production-promotion-contract.ps1'
    'test-initial-production-contract.ps1'
    'test-production-traffic-contract.ps1'
    'test-production-expansion-contract.ps1'
    'test-production-progressive-contract.ps1'
    'test-production-second-expansion-contract.ps1'
    'test-production-final-expansion-contract.ps1'
    'test-production-steady-state-contract.ps1'
    'test-production-assurance-contract.ps1'
    'test-production-incident-response-contract.ps1'
    'test-production-incident-containment-contract.ps1'
    'test-production-incident-recovery-contract.ps1'
    'test-production-incident-recovery-evidence-contract.ps1'
    'test-production-incident-recovery-expansion-contract.ps1'
    'test-production-incident-recovery-expansion-evidence-contract.ps1'
    'test-production-incident-recovery-progressive-contract.ps1'
    'test-production-incident-recovery-progressive-evidence-contract.ps1'
    'test-production-incident-recovery-second-expansion-contract.ps1'
    'test-production-incident-recovery-second-expansion-evidence-contract.ps1'
    'test-production-incident-recovery-final-expansion-contract.ps1'
    'test-production-incident-recovery-final-expansion-evidence-contract.ps1'
    'test-production-incident-recovery-closure-contract.ps1'
    'test-production-incident-recovery-closure-evidence-contract.ps1'
    'test-production-post-incident-assurance-contract.ps1'
    'test-production-assurance-resumption-contract.ps1'
    'test-production-assurance-continuity-contract.ps1'
    'test-production-assurance-recurring-contract.ps1'
    'test-production-assurance-chain-audit-contract.ps1'
    'test-production-assurance-custody-contract.ps1'
    'test-production-assurance-custody-review-contract.ps1'
    'test-production-assurance-custody-recurring-contract.ps1'
    'test-production-assurance-next-renewed-custody-chain-audit-contract.ps1'
    'test-production-assurance-next-renewed-retention-renewal-contract.ps1'
    'test-production-assurance-next-renewed-retention-renewal-evidence-contract.ps1'
    'test-production-assurance-generation-4-custody-baseline-contract.ps1'
    'test-production-assurance-generation-4-custody-review-contract.ps1'
    'test-production-assurance-generation-4-custody-recurring-contract.ps1'
    'test-production-assurance-generation-4-custody-chain-audit-contract.ps1'
)) {
    if (-not $continuousIntegration.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "Continuous Integration workflow is missing required contract '$requiredText'."
    }
}

$containersWorkflow = [System.IO.File]::ReadAllText($containersWorkflowPath)
foreach ($requiredText in @(
    'test-production-acceptance.ps1'
    '-IncludeFailureDrills'
    'steps.version.outputs.value'
    'provenance: mode=max'
    'sbom: true'
)) {
    if (-not $containersWorkflow.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "Containers workflow is missing required contract '$requiredText'."
    }
}

foreach ($relativePath in @(
    'CHANGELOG.md'
    'docs/production-acceptance.md'
    'docs/failure-drills.md'
    'docs/release-runbook.md'
    'docs/staging-rollout.md'
    'docs/production-promotion.md'
    'docs/initial-production-installation.md'
    'docs/production-baseline-and-traffic.md'
    'docs/production-canary-and-expansion.md'
    'docs/production-progressive-expansion.md'
    'docs/production-second-expansion.md'
    'docs/production-final-expansion.md'
    'docs/production-steady-state.md'
    'docs/production-assurance.md'
    'docs/production-incident-response.md'
    'docs/production-incident-containment.md'
    'docs/production-incident-recovery.md'
    'docs/production-incident-recovery-evidence.md'
    'docs/production-incident-recovery-expansion.md'
    'docs/production-incident-recovery-expansion-evidence.md'
    'docs/production-incident-recovery-progressive.md'
    'docs/production-incident-recovery-progressive-evidence.md'
    'docs/production-incident-recovery-second-expansion.md'
    'docs/production-incident-recovery-second-expansion-evidence.md'
    'docs/production-incident-recovery-final-expansion.md'
    'docs/production-incident-recovery-final-expansion-evidence.md'
    'docs/production-incident-recovery-closure.md'
    'docs/production-incident-recovery-closure-evidence.md'
    'docs/production-post-incident-assurance.md'
    'docs/production-assurance-resumption.md'
    'docs/production-assurance-continuity.md'
    'docs/production-assurance-recurring.md'
    'docs/production-assurance-chain-audit.md'
    'docs/production-assurance-evidence-custody.md'
    'docs/production-assurance-custody-review.md'
    'docs/production-assurance-custody-recurring.md'
    'docs/production-assurance-renewed-custody-baseline.md'
    'docs/production-assurance-renewed-custody-review.md'
    'docs/production-assurance-renewed-custody-recurring.md'
    'docs/production-assurance-renewed-custody-chain-audit.md'
    'docs/production-assurance-renewed-retention-renewal.md'
    'docs/production-assurance-renewed-retention-renewal-evidence.md'
    'docs/production-assurance-next-renewed-custody-baseline.md'
    'docs/production-assurance-next-renewed-custody-review.md'
    'docs/production-assurance-next-renewed-custody-recurring.md'
    'docs/production-assurance-next-renewed-custody-chain-audit.md'
    'docs/production-assurance-next-renewed-retention-renewal.md'
    'docs/production-assurance-next-renewed-retention-renewal-evidence.md'
    'docs/production-assurance-generation-4-custody-baseline.md'
    'docs/production-assurance-generation-4-custody-review.md'
    'docs/production-assurance-generation-4-custody-recurring.md'
    'docs/production-assurance-generation-4-custody-chain-audit.md'
    'scripts/new-staging-overlay.ps1'
    'scripts/invoke-staging-rollout.ps1'
    'scripts/new-production-promotion-plan.ps1'
    'scripts/test-production-promotion-plan.ps1'
    'scripts/approve-production-promotion.ps1'
    'scripts/test-production-promotion-contract.ps1'
    'scripts/new-initial-production-plan.ps1'
    'scripts/test-initial-production-plan.ps1'
    'scripts/approve-initial-production-plan.ps1'
    'scripts/test-initial-production-contract.ps1'
    'scripts/new-production-baseline-evidence.ps1'
    'scripts/test-production-baseline-evidence.ps1'
    'scripts/new-production-traffic-plan.ps1'
    'scripts/test-production-traffic-plan.ps1'
    'scripts/approve-production-traffic-plan.ps1'
    'scripts/test-production-traffic-contract.ps1'
    'scripts/new-production-canary-evidence.ps1'
    'scripts/test-production-canary-evidence.ps1'
    'scripts/new-production-expansion-plan.ps1'
    'scripts/test-production-expansion-plan.ps1'
    'scripts/approve-production-expansion-plan.ps1'
    'scripts/test-production-expansion-contract.ps1'
    'scripts/new-production-expansion-evidence.ps1'
    'scripts/test-production-expansion-evidence.ps1'
    'scripts/new-production-progressive-plan.ps1'
    'scripts/test-production-progressive-plan.ps1'
    'scripts/approve-production-progressive-plan.ps1'
    'scripts/test-production-progressive-contract.ps1'
    'scripts/new-production-progressive-evidence.ps1'
    'scripts/test-production-progressive-evidence.ps1'
    'scripts/new-production-second-expansion-plan.ps1'
    'scripts/test-production-second-expansion-plan.ps1'
    'scripts/approve-production-second-expansion-plan.ps1'
    'scripts/test-production-second-expansion-contract.ps1'
    'scripts/new-production-second-expansion-evidence.ps1'
    'scripts/test-production-second-expansion-evidence.ps1'
    'scripts/new-production-final-expansion-plan.ps1'
    'scripts/test-production-final-expansion-plan.ps1'
    'scripts/approve-production-final-expansion-plan.ps1'
    'scripts/test-production-final-expansion-contract.ps1'
    'scripts/new-production-full-traffic-evidence.ps1'
    'scripts/test-production-full-traffic-evidence.ps1'
    'scripts/test-production-steady-state-acceptance.ps1'
    'scripts/test-production-steady-state-contract.ps1'
    'scripts/new-production-assurance-evidence.ps1'
    'scripts/test-production-assurance-evidence.ps1'
    'scripts/test-production-assurance-gate.ps1'
    'scripts/test-production-assurance-contract.ps1'
    'scripts/new-production-incident-response-plan.ps1'
    'scripts/test-production-incident-response-plan.ps1'
    'scripts/approve-production-incident-response-plan.ps1'
    'scripts/test-production-incident-response-contract.ps1'
    'scripts/new-production-incident-containment-evidence.ps1'
    'scripts/test-production-incident-containment-evidence.ps1'
    'scripts/test-production-incident-containment-gate.ps1'
    'scripts/test-production-incident-containment-contract.ps1'
    'scripts/new-production-incident-recovery-plan.ps1'
    'scripts/test-production-incident-recovery-plan.ps1'
    'scripts/approve-production-incident-recovery-plan.ps1'
    'scripts/test-production-incident-recovery-gate.ps1'
    'scripts/test-production-incident-recovery-contract.ps1'
    'scripts/new-production-incident-recovery-evidence.ps1'
    'scripts/test-production-incident-recovery-evidence.ps1'
    'scripts/test-production-incident-recovery-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-evidence-contract.ps1'
    'scripts/new-production-incident-recovery-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-expansion-plan.ps1'
    'scripts/approve-production-incident-recovery-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-expansion-gate.ps1'
    'scripts/test-production-incident-recovery-expansion-contract.ps1'
    'scripts/new-production-incident-recovery-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-expansion-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-expansion-evidence-contract.ps1'
    'scripts/new-production-incident-recovery-progressive-plan.ps1'
    'scripts/test-production-incident-recovery-progressive-plan.ps1'
    'scripts/approve-production-incident-recovery-progressive-plan.ps1'
    'scripts/test-production-incident-recovery-progressive-gate.ps1'
    'scripts/test-production-incident-recovery-progressive-contract.ps1'
    'scripts/new-production-incident-recovery-progressive-evidence.ps1'
    'scripts/test-production-incident-recovery-progressive-evidence.ps1'
    'scripts/test-production-incident-recovery-progressive-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-progressive-evidence-contract.ps1'
    'scripts/new-production-incident-recovery-second-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-second-expansion-plan.ps1'
    'scripts/approve-production-incident-recovery-second-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-second-expansion-gate.ps1'
    'scripts/test-production-incident-recovery-second-expansion-contract.ps1'
    'scripts/new-production-incident-recovery-second-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-second-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-second-expansion-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-second-expansion-evidence-contract.ps1'
    'scripts/new-production-incident-recovery-final-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-final-expansion-plan.ps1'
    'scripts/approve-production-incident-recovery-final-expansion-plan.ps1'
    'scripts/test-production-incident-recovery-final-expansion-gate.ps1'
    'scripts/test-production-incident-recovery-final-expansion-contract.ps1'
    'scripts/new-production-incident-recovery-final-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-final-expansion-evidence.ps1'
    'scripts/test-production-incident-recovery-final-expansion-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-final-expansion-evidence-contract.ps1'
    'scripts/new-production-incident-recovery-closure-plan.ps1'
    'scripts/test-production-incident-recovery-closure-plan.ps1'
    'scripts/approve-production-incident-recovery-closure-plan.ps1'
    'scripts/test-production-incident-recovery-closure-gate.ps1'
    'scripts/test-production-incident-recovery-closure-contract.ps1'
    'scripts/new-production-incident-recovery-closure-evidence.ps1'
    'scripts/test-production-incident-recovery-closure-evidence.ps1'
    'scripts/test-production-incident-recovery-closure-evidence-gate.ps1'
    'scripts/test-production-incident-recovery-closure-evidence-contract.ps1'
    'scripts/new-production-post-incident-assurance-evidence.ps1'
    'scripts/test-production-post-incident-assurance-evidence.ps1'
    'scripts/test-production-post-incident-assurance-gate.ps1'
    'scripts/test-production-post-incident-assurance-contract.ps1'
    'scripts/new-production-assurance-resumption-evidence.ps1'
    'scripts/test-production-assurance-resumption-evidence.ps1'
    'scripts/test-production-assurance-resumption-gate.ps1'
    'scripts/test-production-assurance-resumption-contract.ps1'
    'scripts/new-production-assurance-continuity-evidence.ps1'
    'scripts/test-production-assurance-continuity-evidence.ps1'
    'scripts/test-production-assurance-continuity-gate.ps1'
    'scripts/test-production-assurance-continuity-contract.ps1'
    'scripts/new-production-assurance-recurring-evidence.ps1'
    'scripts/test-production-assurance-recurring-evidence.ps1'
    'scripts/test-production-assurance-recurring-gate.ps1'
    'scripts/test-production-assurance-recurring-contract.ps1'
    'scripts/new-production-assurance-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-chain-audit-gate.ps1'
    'scripts/test-production-assurance-chain-audit-contract.ps1'
    'scripts/new-production-assurance-custody-evidence.ps1'
    'scripts/test-production-assurance-custody-evidence.ps1'
    'scripts/test-production-assurance-custody-gate.ps1'
    'scripts/test-production-assurance-custody-contract.ps1'
    'scripts/new-production-assurance-custody-review-evidence.ps1'
    'scripts/test-production-assurance-custody-review-evidence.ps1'
    'scripts/test-production-assurance-custody-review-gate.ps1'
    'scripts/test-production-assurance-custody-review-contract.ps1'
    'scripts/new-production-assurance-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-custody-recurring-gate.ps1'
    'scripts/test-production-assurance-custody-recurring-contract.ps1'
    'scripts/new-production-assurance-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-custody-chain-audit-gate.ps1'
    'scripts/test-production-assurance-custody-chain-audit-contract.ps1'
    'scripts/new-production-assurance-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-retention-renewal-plan.ps1'
    'scripts/approve-production-assurance-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-retention-renewal-gate.ps1'
    'scripts/test-production-assurance-retention-renewal-contract.ps1'
    'scripts/new-production-assurance-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-retention-renewal-evidence-gate.ps1'
    'scripts/test-production-assurance-retention-renewal-evidence-contract.ps1'
    'scripts/new-production-assurance-renewed-custody-baseline.ps1'
    'scripts/test-production-assurance-renewed-custody-baseline.ps1'
    'scripts/test-production-assurance-renewed-custody-baseline-gate.ps1'
    'scripts/test-production-assurance-renewed-custody-baseline-contract.ps1'
    'scripts/new-production-assurance-renewed-custody-review-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-review-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-review-gate.ps1'
    'scripts/test-production-assurance-renewed-custody-review-contract.ps1'
    'scripts/new-production-assurance-renewed-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-recurring-gate.ps1'
    'scripts/test-production-assurance-renewed-custody-recurring-contract.ps1'
    'scripts/new-production-assurance-renewed-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-renewed-custody-chain-audit-gate.ps1'
    'scripts/test-production-assurance-renewed-custody-chain-audit-contract.ps1'
    'scripts/new-production-assurance-renewed-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-plan.ps1'
    'scripts/approve-production-assurance-renewed-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-gate.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-contract.ps1'
    'scripts/new-production-assurance-renewed-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-evidence-gate.ps1'
    'scripts/test-production-assurance-renewed-retention-renewal-evidence-contract.ps1'
    'scripts/new-production-assurance-next-renewed-custody-baseline.ps1'
    'scripts/test-production-assurance-next-renewed-custody-baseline.ps1'
    'scripts/test-production-assurance-next-renewed-custody-baseline-gate.ps1'
    'scripts/test-production-assurance-next-renewed-custody-baseline-contract.ps1'
    'scripts/new-production-assurance-next-renewed-custody-review-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-review-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-review-gate.ps1'
    'scripts/test-production-assurance-next-renewed-custody-review-contract.ps1'
    'scripts/new-production-assurance-next-renewed-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-recurring-gate.ps1'
    'scripts/test-production-assurance-next-renewed-custody-recurring-contract.ps1'
    'scripts/new-production-assurance-next-renewed-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-custody-chain-audit-gate.ps1'
    'scripts/test-production-assurance-next-renewed-custody-chain-audit-contract.ps1'
    'scripts/new-production-assurance-next-renewed-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-plan.ps1'
    'scripts/approve-production-assurance-next-renewed-retention-renewal-plan.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-gate.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-contract.ps1'
    'scripts/new-production-assurance-next-renewed-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-evidence.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-evidence-gate.ps1'
    'scripts/test-production-assurance-next-renewed-retention-renewal-evidence-contract.ps1'
    'scripts/new-production-assurance-generation-4-custody-baseline.ps1'
    'scripts/test-production-assurance-generation-4-custody-baseline.ps1'
    'scripts/test-production-assurance-generation-4-custody-baseline-gate.ps1'
    'scripts/test-production-assurance-generation-4-custody-baseline-contract.ps1'
    'scripts/new-production-assurance-generation-4-custody-review-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-review-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-review-gate.ps1'
    'scripts/test-production-assurance-generation-4-custody-review-contract.ps1'
    'scripts/new-production-assurance-generation-4-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-recurring-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-recurring-gate.ps1'
    'scripts/test-production-assurance-generation-4-custody-recurring-contract.ps1'
    'scripts/new-production-assurance-generation-4-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-chain-audit-evidence.ps1'
    'scripts/test-production-assurance-generation-4-custody-chain-audit-gate.ps1'
    'scripts/test-production-assurance-generation-4-custody-chain-audit-contract.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf)) {
        throw "Required release artifact is missing: $relativePath"
    }
}

Push-Location $repoRoot
try {
    $gitRoot = (& git rev-parse --show-toplevel 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse failed: $gitRoot"
    }
    if (-not [string]::Equals(
        (Resolve-Path -LiteralPath $gitRoot).Path,
        $repoRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Release check is running against the wrong repository root: $gitRoot"
    }

    if ($RequireClean) {
        $changes = @(& git status --porcelain=v1 --untracked-files=all)
        if ($LASTEXITCODE -ne 0) {
            throw 'git status failed.'
        }
        if ($changes.Count -ne 0) {
            throw "Release requires a clean checkout. Changes:`n$($changes -join "`n")"
        }
    }

    if ($RequireTag) {
        $expectedTag = "v$Version"
        $headTags = @(& git tag --points-at HEAD)
        if ($LASTEXITCODE -ne 0) {
            throw 'git tag --points-at HEAD failed.'
        }
        if ($headTags -notcontains $expectedTag) {
            throw "HEAD is not tagged with the expected release tag '$expectedTag'."
        }
    }
}
finally {
    Pop-Location
}

Write-Host "Release metadata is consistent for v$Version."
