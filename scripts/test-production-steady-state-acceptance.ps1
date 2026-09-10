[CmdletBinding()]
param(
    [string]$EvidencePath = '.shieldward/production-full-traffic-evidence/evidence.json',
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
& (Join-Path $PSScriptRoot 'test-production-full-traffic-evidence.ps1') @validationArguments | Out-Null
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json

if ([string]$evidence.outcome -ne 'passed') {
    throw "Production steady-state acceptance requires passed full-traffic evidence; outcome is '$($evidence.outcome)'."
}
if (
    [int]$evidence.observation.observedTrafficPercent -ne 100 -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [bool]$evidence.checks.trafficControllerExternallyEnforced -ne $true
) {
    throw 'Production steady-state acceptance requires externally enforced, observed 100 percent traffic.'
}

$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$endedAt = [DateTimeOffset]$evidence.observation.endedAtUtc
$now = [DateTimeOffset]::UtcNow
$collectedAge = $now - $collectedAt.ToUniversalTime()
$observationAge = $now - $endedAt.ToUniversalTime()
if (
    $collectedAge.TotalMinutes -lt -5 -or
    $collectedAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt $MaxEvidenceAgeMinutes
) {
    throw "Production full-traffic evidence is outside the accepted age of $MaxEvidenceAgeMinutes minutes."
}

Write-Host "Production steady-state acceptance passed for release $($evidence.candidate.version) at 100% traffic."
Write-Host 'This gate verifies recorded evidence; it does not enforce traffic or replace the authoritative change system.'
