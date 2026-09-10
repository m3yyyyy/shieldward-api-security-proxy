[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$RecoveryPlanPath = '',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationArguments = @{
    EvidencePath = $EvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($RecoveryPlanPath)) {
    $validationArguments.RecoveryPlanPath = $RecoveryPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    $validationArguments.ContainmentEvidencePath = $ContainmentEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $validationArguments.ResponsePlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') @validationArguments 6>$null

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

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
if ($evidenceAge.TotalMinutes -lt -5 -or $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes) {
    throw "Production incident recovery evidence is stale or future-dated; maximum age is $MaxEvidenceAgeMinutes minutes."
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.execution.status -ne 'completed' -or
    [bool]$evidence.traffic.matchesPlan -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [string]$evidence.verification.workloads -ne 'confirmed' -or
    [string]$evidence.verification.functional -ne 'passed' -or
    [string]$evidence.verification.dependencies -ne 'healthy' -or
    [string]$evidence.verification.operations -ne 'healthy' -or
    [string]$evidence.verification.capacity -ne 'healthy' -or
    [string]$evidence.verification.security -ne 'clear' -or
    [string]$evidence.verification.drift -ne 'clear' -or
    [string]$evidence.verification.certificates -ne 'healthy' -or
    [string]$evidence.verification.rollbackReadiness -ne 'ready' -or
    [string]$evidence.verification.incidentRecord -ne 'updated' -or
    [string]$evidence.verification.recoveryChangeRecord -ne 'updated' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [string]$evidence.decision.nextAction -eq 'restore-contained-boundary-and-escalate'
) {
    throw 'Production incident recovery execution is not proven; restore the contained boundary and escalate.'
}
if (
    [int]$evidence.traffic.expectedPercent -lt 100 -and
    [bool]$evidence.decision.fullTrafficRestored
) {
    throw 'A bounded recovery canary must not be represented as full-traffic restoration.'
}
if (
    [int]$evidence.traffic.expectedPercent -eq 100 -and
    -not [bool]$evidence.decision.fullTrafficRestored
) {
    throw 'The evidence did not preserve the full-traffic recovery decision.'
}

Write-Host "Production incident recovery execution gate passed for incident $($evidence.incidentId)."
Write-Host "Externally enforced recovery target: $($evidence.traffic.observedPercent)%; next action: $($evidence.decision.nextAction)"
Write-Host 'This gate proves only the recorded target; it does not authorize further expansion or close the incident.'
