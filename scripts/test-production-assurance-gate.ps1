[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$AcceptedFullTrafficEvidencePath = '',
    [string]$FinalExpansionPlanPath = '',
    [string]$SecondExpansionEvidencePath = '',
    [string]$SecondExpansionPlanPath = '',
    [string]$ProgressiveEvidencePath = '',
    [string]$ProgressivePlanPath = '',
    [string]$ExpansionEvidencePath = '',
    [string]$ExpansionPlanPath = '',
    [string]$CanaryEvidencePath = '',
    [string]$TrafficPlanPath = '',
    [string]$BaselineEvidencePath = '',
    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 10080)]
    [int]$MaxEvidenceAgeMinutes = 1440,

    [switch]$CheckCluster
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
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'AcceptedFullTrafficEvidencePath'; Value = $AcceptedFullTrafficEvidencePath }
    [pscustomobject]@{ Name = 'FinalExpansionPlanPath'; Value = $FinalExpansionPlanPath }
    [pscustomobject]@{ Name = 'SecondExpansionEvidencePath'; Value = $SecondExpansionEvidencePath }
    [pscustomobject]@{ Name = 'SecondExpansionPlanPath'; Value = $SecondExpansionPlanPath }
    [pscustomobject]@{ Name = 'ProgressiveEvidencePath'; Value = $ProgressiveEvidencePath }
    [pscustomobject]@{ Name = 'ProgressivePlanPath'; Value = $ProgressivePlanPath }
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'CanaryEvidencePath'; Value = $CanaryEvidencePath }
    [pscustomobject]@{ Name = 'TrafficPlanPath'; Value = $TrafficPlanPath }
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $validationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-assurance-evidence.ps1') @validationArguments | Out-Null
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json

if ([string]$evidence.outcome -ne 'passed') {
    throw "Production assurance requires passed evidence; outcome is '$($evidence.outcome)'."
}
if (
    [bool]$evidence.decision.reacceptanceRequired -ne $false -or
    [string]$evidence.decision.requiredAction -ne 'continue-monitoring'
) {
    throw 'Production assurance is blocked until the recorded re-acceptance or response action is complete.'
}
if (
    [int]$evidence.traffic.observedTrafficPercent -ne 100 -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [bool]$evidence.checks.trafficControllerExternallyEnforced -ne $true
) {
    throw 'Production assurance requires externally enforced, observed 100 percent traffic.'
}

try {
    $collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
    $nextReviewDueAt = [DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc
}
catch {
    throw 'Production assurance evidence contains an invalid freshness boundary.'
}
$now = [DateTimeOffset]::UtcNow
$evidenceAge = $now - $collectedAt.ToUniversalTime()
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $now -gt $nextReviewDueAt.AddMinutes(5)
) {
    throw 'Production assurance evidence is stale or its next review is overdue.'
}

Write-Host "Production assurance gate passed for release $($evidence.candidate.version) at 100% traffic."
Write-Host "Next review is due at $($nextReviewDueAt.ToUniversalTime().ToString('o'))."
Write-Host 'This gate is read-only and does not authorize drift or change production state.'
