[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainHeadEvidencePath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateRange(5, 1440)][int]$MaxEvidenceAgeMinutes = 60,
    [switch]$CheckCluster,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$resolvedEvidencePath = if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
    [System.IO.Path]::GetFullPath($EvidencePath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $EvidencePath))
}
if (-not $resolvedEvidencePath.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidencePath must be beneath the ignored .shieldward directory.'
}

$validationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    $validationArguments.ChainHeadEvidencePath = $ChainHeadEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') @validationArguments 6>$null
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
try {
    $collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
    $auditCompletedAt = ([DateTimeOffset]$evidence.audit.completedAtUtc).ToUniversalTime()
}
catch {
    throw 'Production assurance chain audit evidence contains an invalid freshness boundary.'
}
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $auditCompletedAt -gt $referenceNow.AddMinutes(5)
) {
    throw 'Production assurance chain audit evidence is stale or future-dated.'
}

if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.chain.verified -ne $true -or
    [int]$evidence.chain.firstSequence -ne 1 -or
    [int]$evidence.chain.headSequence -lt 2 -or
    [int]$evidence.chain.entryCount -ne [int]$evidence.chain.headSequence -or
    [string]$evidence.audit.chainHeadGateStatus -ne 'passed' -or
    [string]$evidence.audit.chainInventoryStatus -ne 'complete' -or
    [string]$evidence.audit.evidenceRetentionStatus -ne 'retained' -or
    [string]$evidence.audit.independentReviewStatus -ne 'passed' -or
    [string]$evidence.audit.accessAuditStatus -ne 'passed' -or
    [bool]$evidence.decision.chainVerified -ne $true -or
    [bool]$evidence.decision.auditPassed -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Production assurance chain audit is not proven; preserve the evidence chain and follow the recorded response action.'
}

Write-Host "Production assurance chain audit gate passed for release $($evidence.candidate.version)."
Write-Host "Verified retained review sequences 1 through $($evidence.chain.headSequence); chain digest: $($evidence.chain.digest)"
Write-Host 'This gate proves only the recorded audit checkpoint; it does not schedule reviews, retain evidence, or change production.'
