[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PreviousContinuityEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($PreviousContinuityEvidencePath)) {
    $validationArguments.PreviousContinuityEvidencePath = $PreviousContinuityEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') @validationArguments 6>$null
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
    $completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
    $nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
}
catch {
    throw 'Recurring production assurance evidence contains an invalid freshness boundary.'
}
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $referenceNow -gt $nextReviewDueAt.AddMinutes(5) -or
    $completedAt -gt $referenceNow.AddMinutes(5)
) {
    throw 'Recurring production assurance evidence is stale, future-dated, or overdue for its next review.'
}

if (
    [string]$evidence.outcome -ne 'passed' -or
    [int]$evidence.review.sequence -lt 2 -or
    [int]$evidence.review.previousSequence -ne ([int]$evidence.review.sequence - 1) -or
    [string]$evidence.review.executionStatus -ne 'completed' -or
    [bool]$evidence.review.onTime -ne $true -or
    [string]$evidence.schedule.status -ne 'active' -or
    [string]$evidence.schedule.monitoringCoverage -ne 'complete' -or
    [string]$evidence.signals.errorBudget -ne 'within-budget' -or
    [string]$evidence.signals.alerts -ne 'clear' -or
    [string]$evidence.signals.functional -ne 'passed' -or
    [string]$evidence.signals.dependencies -ne 'healthy' -or
    [string]$evidence.signals.operations -ne 'healthy' -or
    [string]$evidence.signals.capacity -ne 'healthy' -or
    [string]$evidence.signals.security -ne 'clear' -or
    [string]$evidence.drift.images -ne 'clear' -or
    [string]$evidence.drift.policy -ne 'clear' -or
    [string]$evidence.drift.configuration -ne 'clear' -or
    [string]$evidence.drift.identity -ne 'clear' -or
    [string]$evidence.drift.certificates -ne 'healthy' -or
    [string]$evidence.drift.routing -ne 'clear' -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [int]$evidence.traffic.observedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesPrevious -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0 -or
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$evidence.rollback.retentionStatus -ne 'retained' -or
    [bool]$evidence.decision.monitoringContinues -ne $true -or
    [bool]$evidence.decision.continuityLinkValid -ne $true -or
    [bool]$evidence.decision.continuityProven -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Recurring production assurance continuity is not proven; preserve rollback and follow the recorded response action.'
}

Write-Host "Recurring production assurance gate passed for release $($evidence.candidate.version)."
Write-Host "Review sequence $($evidence.review.sequence) follows sequence $($evidence.review.previousSequence); next review: $($nextReviewDueAt.ToString('o'))"
Write-Host 'This gate proves only the recorded recurring review chain; it does not schedule reviews, change production, or remove rollback.'
