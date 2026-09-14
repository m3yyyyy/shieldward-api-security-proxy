[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
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
& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-evidence.ps1') @validationArguments 6>$null

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
    throw 'Production assurance resumption evidence is stale, future-dated, or already overdue for its next review.'
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.postIncidentEvidence.outcome -ne 'passed' -or
    [bool]$evidence.postIncidentEvidence.retrospectiveRecorded -ne $true -or
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
    [bool]$evidence.traffic.matchesPostIncident -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0 -or
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$evidence.rollback.retentionStatus -ne 'retained' -or
    [bool]$evidence.decision.monitoringActivated -ne $true -or
    [bool]$evidence.decision.assuranceResumed -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Continuous production assurance resumption is not proven; preserve rollback and follow the recorded response action.'
}

Write-Host "Continuous production assurance resumption gate passed for release $($evidence.candidate.version)."
Write-Host "Next review is due at $($nextReviewDueAt.ToString('o')); action: $($evidence.decision.nextAction)"
Write-Host 'This gate proves only recorded resumption evidence; it does not activate a scheduler, change production, or remove rollback.'
