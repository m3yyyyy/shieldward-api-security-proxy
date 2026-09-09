[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string]$ControlPlaneDigest,

    [Parameter(Mandatory)]
    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string]$EdgeDigest,

    [string]$OutputDirectory = '.shieldward/staging',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$semanticVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($Version -notmatch $semanticVersionPattern) {
    throw "Release version '$Version' is not a supported semantic version."
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    throw 'OutputDirectory must not be empty.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$resolvedOutputDirectory = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}

$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedOutputDirectory.StartsWith(
    $localStatePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The staging overlay must be generated beneath the ignored .shieldward directory.'
}

$kustomizationPath = Join-Path $resolvedOutputDirectory 'kustomization.yaml'
$metadataPath = Join-Path $resolvedOutputDirectory 'rollout.json'
$existingFiles = @(
    @($kustomizationPath, $metadataPath) | Where-Object {
        Test-Path -LiteralPath $_
    }
)
if ($existingFiles.Count -gt 0 -and -not $Force) {
    throw "Staging output already exists. Use -Force to replace only the generated files:`n$($existingFiles -join "`n")"
}

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$baseDirectory = Join-Path $repoRoot 'deploy/kubernetes/base'
$relativeBase = [System.IO.Path]::GetRelativePath(
    $resolvedOutputDirectory,
    $baseDirectory
).Replace('\', '/')
$controlPlaneRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane'
$edgeRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge'

$kustomization = @"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - $relativeBase

images:
  - name: $controlPlaneRepository
    newName: $controlPlaneRepository
    digest: $ControlPlaneDigest
  - name: $edgeRepository
    newName: $edgeRepository
    digest: $EdgeDigest
"@

$metadata = [ordered]@{
    schemaVersion = 1
    environment = 'staging'
    namespace = 'shieldward'
    releaseVersion = $Version
    sourceTag = "v$Version"
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    images = [ordered]@{
        controlPlane = [ordered]@{
            repository = $controlPlaneRepository
            digest = $ControlPlaneDigest
            reference = "$controlPlaneRepository@$ControlPlaneDigest"
        }
        edge = [ordered]@{
            repository = $edgeRepository
            digest = $EdgeDigest
            reference = "$edgeRepository@$EdgeDigest"
        }
    }
}

[System.IO.File]::WriteAllText($kustomizationPath, "$kustomization`n")
[System.IO.File]::WriteAllText(
    $metadataPath,
    (($metadata | ConvertTo-Json -Depth 6) + "`n")
)

$writtenKustomization = [System.IO.File]::ReadAllText($kustomizationPath)
foreach ($requiredText in @(
    "digest: $ControlPlaneDigest"
    "digest: $EdgeDigest"
    $relativeBase
)) {
    if (-not $writtenKustomization.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "Generated staging overlay is missing '$requiredText'."
    }
}

Write-Host "Digest-pinned staging overlay created at $resolvedOutputDirectory"
Write-Host 'No credentials were written. Create the required Kubernetes secrets separately.'
