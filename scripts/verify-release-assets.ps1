[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Directory,
    [Parameter(Mandatory)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$semanticVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($Version -notmatch $semanticVersionPattern) {
    throw "Release version '$Version' is not a supported semantic version."
}

$releaseDirectory = (Resolve-Path -LiteralPath $Directory).Path
$checksumPath = Join-Path $releaseDirectory 'SHA256SUMS'
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw 'Release bundle does not contain SHA256SUMS.'
}

$expectedArtifacts = @(
    "shieldward-edge-$Version.tar.gz"
    'shieldward-source.spdx.json'
    'shieldwardd-linux-amd64'
    'shieldwardd-linux-arm64'
    'shieldwardd-windows-amd64.exe'
    'shieldwardd-windows-arm64.exe'
) | Sort-Object

$actualArtifacts = @(
    Get-ChildItem -LiteralPath $releaseDirectory -File |
        Where-Object Name -ne 'SHA256SUMS' |
        Select-Object -ExpandProperty Name |
        Sort-Object
)

$inventoryDifference = @(Compare-Object $expectedArtifacts $actualArtifacts)
if ($inventoryDifference.Count -ne 0) {
    throw "Release artifact inventory is not exact:`n$($inventoryDifference | Out-String)"
}

$recordedHashes = [System.Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::Ordinal
)
$checksumLines = [System.IO.File]::ReadAllLines($checksumPath)
foreach ($line in $checksumLines) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    if ($line -notmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$') {
        throw "SHA256SUMS contains an unsafe or malformed entry: $line"
    }

    $name = $Matches[2]
    if (-not $recordedHashes.TryAdd($name, $Matches[1].ToLowerInvariant())) {
        throw "SHA256SUMS contains duplicate entry '$name'."
    }
}

if ($recordedHashes.Count -ne $expectedArtifacts.Count) {
    throw 'SHA256SUMS does not contain exactly one entry for each release artifact.'
}

foreach ($name in $expectedArtifacts) {
    if (-not $recordedHashes.ContainsKey($name)) {
        throw "SHA256SUMS is missing '$name'."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $releaseDirectory $name)).Hash.ToLowerInvariant()
    if ($actualHash -ne $recordedHashes[$name]) {
        throw "SHA-256 verification failed for '$name'."
    }
}

$sbom = Get-Content -Raw -LiteralPath (Join-Path $releaseDirectory 'shieldward-source.spdx.json') |
    ConvertFrom-Json
if ([string]$sbom.spdxVersion -notmatch '^SPDX-2\.[0-9]+$') {
    throw 'Release SBOM is not valid SPDX JSON metadata.'
}

$edgeArchive = Join-Path $releaseDirectory "shieldward-edge-$Version.tar.gz"
$archiveEntries = @(& tar -tzf $edgeArchive)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list the Edge release archive.'
}
foreach ($entry in $archiveEntries) {
    if ($entry -match '(^/)|(^|/)\.\.(/|$)|^[A-Za-z]:') {
        throw "Edge archive contains unsafe path '$entry'."
    }
}
foreach ($requiredEntry in @(
    'edge/dist/index.js'
    'edge/package.json'
    'edge/package-lock.json'
)) {
    if ($archiveEntries -notcontains $requiredEntry) {
        throw "Edge archive is missing '$requiredEntry'."
    }
}

$archivedPackageText = (& tar -xOzf $edgeArchive 'edge/package.json') -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read package.json from the Edge release archive.'
}
$archivedPackage = $archivedPackageText | ConvertFrom-Json
if ([string]$archivedPackage.version -ne $Version) {
    throw "Edge archive reports version '$($archivedPackage.version)'; expected '$Version'."
}

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$versionBinary = $null
if ($IsLinux -and $architecture -eq 'x64') {
    $versionBinary = Join-Path $releaseDirectory 'shieldwardd-linux-amd64'
}
elseif ($IsLinux -and $architecture -eq 'arm64') {
    $versionBinary = Join-Path $releaseDirectory 'shieldwardd-linux-arm64'
}
elseif ($IsWindows -and $architecture -eq 'x64') {
    $versionBinary = Join-Path $releaseDirectory 'shieldwardd-windows-amd64.exe'
}
elseif ($IsWindows -and $architecture -eq 'arm64') {
    $versionBinary = Join-Path $releaseDirectory 'shieldwardd-windows-arm64.exe'
}

if ($null -ne $versionBinary) {
    $reportedVersion = (& $versionBinary version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Release binary version command failed: $reportedVersion"
    }
    if ($reportedVersion -ne $Version) {
        throw "Release binary reports version '$reportedVersion'; expected '$Version'."
    }
}

Write-Host "Verified release artifact inventory, checksums, SBOM, archive, and version for v$Version."
