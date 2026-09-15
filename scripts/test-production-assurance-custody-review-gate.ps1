[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$CustodyEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($CustodyEvidencePath)) {
    $validationArguments.CustodyEvidencePath = $CustodyEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-evidence.ps1') @validationArguments 6>$null
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
    $nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
    $retentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
}
catch {
    throw 'Production assurance custody review evidence contains an invalid freshness boundary.'
}
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $nextReviewDueAt -le $referenceNow -or
    $retentionUntil -le $nextReviewDueAt
) {
    throw 'Production assurance custody review evidence is stale, overdue, or outside its retention schedule.'
}

if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.custodyEvidence.outcome -ne 'passed' -or
    [bool]$evidence.custodyEvidence.custodyConfirmed -ne $true -or
    [bool]$evidence.review.onTime -ne $true -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $true -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $true -or
    [string]$evidence.controls.archiveAvailability -ne 'available' -or
    [string]$evidence.controls.evidenceInventory -ne 'complete' -or
    [string]$evidence.controls.objectLock -ne 'enforced' -or
    [string]$evidence.controls.retentionPolicy -ne 'active' -or
    [string]$evidence.controls.encryption -ne 'verified' -or
    [string]$evidence.controls.accessControl -ne 'least-privilege' -or
    [string]$evidence.controls.restoreVerification -ne 'passed' -or
    [bool]$evidence.decision.custodyLinkValid -ne $true -or
    [bool]$evidence.decision.custodyContinuityProven -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Production assurance custody continuity is not proven; preserve evidence and follow the recorded response action.'
}

Write-Host "Production assurance custody review gate passed for release $($evidence.candidate.version)."
Write-Host "The next custody review is due at $($nextReviewDueAt.ToString('o')) before retention ends at $($retentionUntil.ToString('o'))."
Write-Host 'This gate proves only the recorded custody review; it does not schedule, retain, restore, delete, or change production evidence.'
