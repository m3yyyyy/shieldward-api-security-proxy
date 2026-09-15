[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainAuditEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($ChainAuditEvidencePath)) {
    $validationArguments.ChainAuditEvidencePath = $ChainAuditEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-evidence.ps1') @validationArguments 6>$null
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
    $archivedAt = ([DateTimeOffset]$evidence.archive.archivedAtUtc).ToUniversalTime()
    $retentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
}
catch {
    throw 'Production assurance evidence custody contains an invalid freshness or retention boundary.'
}
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $archivedAt -gt $referenceNow.AddMinutes(5) -or
    $retentionUntil -le $referenceNow
) {
    throw 'Production assurance evidence custody is stale, future-dated, or outside its retention window.'
}

if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.chainAuditEvidence.auditPassed -ne $true -or
    [int]$evidence.chainAuditEvidence.headReviewSequence -lt 2 -or
    [bool]$evidence.archive.auditChecksumMatches -ne $true -or
    [bool]$evidence.archive.chainDigestMatches -ne $true -or
    [string]$evidence.archive.writeStatus -ne 'completed' -or
    [string]$evidence.archive.objectLockStatus -ne 'enforced' -or
    [string]$evidence.retention.policyStatus -ne 'active' -or
    [bool]$evidence.retention.meetsPolicy -ne $true -or
    [string]$evidence.archive.encryptionStatus -ne 'verified' -or
    [string]$evidence.archive.accessControlStatus -ne 'least-privilege' -or
    [string]$evidence.archive.restoreVerificationStatus -ne 'passed' -or
    [bool]$evidence.decision.custodyConfirmed -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Production assurance evidence custody is not confirmed; preserve local evidence and follow the recorded response action.'
}

Write-Host "Production assurance evidence custody gate passed for release $($evidence.candidate.version)."
Write-Host "Archived audit for chain sequence $($evidence.chainAuditEvidence.headReviewSequence) remains within retention through $($retentionUntil.ToString('o'))."
Write-Host 'This gate proves only recorded external custody evidence; it does not upload, lock, retain, restore, or delete evidence.'
