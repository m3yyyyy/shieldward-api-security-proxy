[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery/recovery.json',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 1440)]
    [int]$MaxPlanAgeMinutes = 60,

    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationArguments = @{
    PlanPath = $PlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    $validationArguments.ContainmentEvidencePath = $ContainmentEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $validationArguments.ResponsePlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') @validationArguments 6>$null

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$resolvedPlanPath = if ([System.IO.Path]::IsPathRooted($PlanPath)) {
    [System.IO.Path]::GetFullPath($PlanPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PlanPath))
}
if (-not $resolvedPlanPath.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PlanPath must be beneath the ignored .shieldward directory.'
}

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$generatedAt = [DateTimeOffset]$plan.generatedAtUtc
$expiresAt = [DateTimeOffset]$plan.expiresAtUtc
$planAge = [DateTimeOffset]::UtcNow - $generatedAt.ToUniversalTime()
if (
    $planAge.TotalMinutes -lt -5 -or
    $planAge.TotalMinutes -gt $MaxPlanAgeMinutes -or
    [DateTimeOffset]::UtcNow -gt $expiresAt.ToUniversalTime()
) {
    throw "Production incident recovery authorization is stale, future-dated, or expired; maximum age is $MaxPlanAgeMinutes minutes."
}
if (
    [string]$plan.readiness.outcome -ne 'passed' -or
    [string]$plan.traffic.currentStatus -ne 'confirmed' -or
    [bool]$plan.traffic.externallyConfirmed -ne $true -or
    [string]$plan.readiness.functionalStatus -ne 'passed' -or
    [string]$plan.readiness.dependencyStatus -ne 'healthy' -or
    [string]$plan.readiness.operationalStatus -ne 'healthy' -or
    [string]$plan.readiness.capacityStatus -ne 'healthy' -or
    [string]$plan.readiness.securityStatus -ne 'clear' -or
    [string]$plan.readiness.driftStatus -ne 'clear' -or
    [string]$plan.readiness.certificateStatus -ne 'healthy' -or
    [string]$plan.readiness.incidentRecordStatus -ne 'updated' -or
    [string]$plan.readiness.recoveryChangeStatus -ne 'approved' -or
    ([bool]$plan.readiness.remediationRequired -and [string]$plan.readiness.remediationStatus -ne 'completed') -or
    ([bool]$plan.readiness.reacceptanceRequired -and [string]$plan.readiness.reacceptanceStatus -ne 'passed') -or
    [string]$plan.recovery.executionState -ne 'not-started' -or
    [string]$plan.decision.afterApprovalAction -ne 'execute-approved-recovery-externally'
) {
    throw 'Production incident recovery is not authorized; hold the contained traffic boundary and preserve evidence.'
}

Write-Host "Production incident recovery gate passed for incident $($plan.incidentId)."
Write-Host "Authorized external boundary: $($plan.traffic.currentPercent)% to $($plan.traffic.targetPercent)%."
Write-Host 'This gate authorizes only the recorded external action; it does not change production state or prove traffic restoration.'
