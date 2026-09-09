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
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf)) {
        throw "Required release document is missing: $relativePath"
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
