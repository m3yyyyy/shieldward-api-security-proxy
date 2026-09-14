[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

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
if (-not [string]::IsNullOrWhiteSpace($ClosureEvidencePath)) {
    $validationArguments.ClosureEvidencePath = $ClosureEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ClosurePlanPath)) {
    $validationArguments.ClosurePlanPath = $ClosurePlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-evidence.ps1') @validationArguments 6>$null

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
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes
) {
    throw "Post-incident assurance evidence is stale or future-dated; maximum age is $MaxEvidenceAgeMinutes minutes."
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.closureEvidence.closureRecorded -ne $true -or
    [string]$evidence.incident.status -ne 'closed' -or
    [bool]$evidence.incident.authoritativeExternalSystemRequired -ne $true -or
    [bool]$evidence.incident.performedByRepository -ne $false -or
    [string]$evidence.assurance.sustainedHealth -ne 'healthy' -or
    [string]$evidence.assurance.errorBudget -ne 'within-budget' -or
    [string]$evidence.assurance.securityReview -ne 'complete' -or
    [string]$evidence.retrospective.rootCauseAnalysis -ne 'complete' -or
    [string]$evidence.retrospective.correctiveActions -ne 'tracked' -or
    [string]$evidence.retrospective.status -ne 'completed' -or
    [bool]$evidence.retrospective.recorded -ne $true -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [int]$evidence.traffic.observedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesClosure -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0 -or
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$evidence.rollback.retentionStatus -ne 'retained' -or
    [string]$evidence.audit.status -ne 'complete' -or
    [bool]$evidence.decision.retrospectiveRecorded -ne $true -or
    [string]$evidence.decision.nextAction -ne 'resume-continuous-production-assurance'
) {
    throw 'Post-incident assurance is not proven; preserve rollback and collect or escalate authoritative evidence.'
}

Write-Host "Post-incident assurance and retrospective gate passed for incident $($evidence.incidentId)."
Write-Host "Retrospective recorded: $($evidence.retrospective.recorded); next action: $($evidence.decision.nextAction)"
Write-Host 'This gate proves only recorded assurance and retrospective evidence; it does not change traffic, incidents, external records, or rollback state.'
