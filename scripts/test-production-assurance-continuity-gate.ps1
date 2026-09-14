[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ResumptionEvidencePath = '',
    [string]$PostIncidentEvidencePath = '',
    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateRange(5, 1440)][int]$MaxEvidenceAgeMinutes = 60,
    [switch]$CheckCluster,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc) -and $ExpectedProductionContext -ne 'production-contract') {
    throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
}

$validationArguments = @{
    EvidencePath = $EvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ResumptionEvidencePath'; Value = $ResumptionEvidencePath }
    [pscustomobject]@{ Name = 'PostIncidentEvidencePath'; Value = $PostIncidentEvidencePath }
    [pscustomobject]@{ Name = 'ClosureEvidencePath'; Value = $ClosureEvidencePath }
    [pscustomobject]@{ Name = 'ClosurePlanPath'; Value = $ClosurePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $validationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-continuity-evidence.ps1') @validationArguments 6>$null

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

$referenceNow = if ([string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    [DateTimeOffset]::UtcNow
}
else {
    ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $referenceNow -gt $nextReviewDueAt.AddMinutes(5)
) {
    throw 'Production assurance continuity evidence is stale, future-dated, or overdue for its next review.'
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.resumptionEvidence.outcome -ne 'passed' -or
    [bool]$evidence.resumptionEvidence.assuranceResumed -ne $true -or
    [int]$evidence.review.sequence -ne 1 -or
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
    [bool]$evidence.traffic.matchesResumption -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0 -or
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$evidence.rollback.retentionStatus -ne 'retained' -or
    [bool]$evidence.decision.monitoringContinues -ne $true -or
    [bool]$evidence.decision.continuityProven -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Scheduled production assurance continuity is not proven; preserve rollback and follow the recorded response action.'
}

Write-Host "Scheduled production assurance continuity gate passed for release $($evidence.candidate.version)."
Write-Host "Review sequence $($evidence.review.sequence) completed on time; next review: $($nextReviewDueAt.ToString('o'))"
Write-Host 'This gate proves only recorded continuity evidence; it does not schedule reviews, change production, or remove rollback.'
