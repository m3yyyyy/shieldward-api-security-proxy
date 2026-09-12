[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery-second-expansion/expansion.json',
    [string]$ProgressiveEvidencePath = '',
    [string]$ProgressivePlanPath = '',
    [string]$ExpansionEvidencePath = '',
    [string]$ExpansionPlanPath = '',
    [string]$RecoveryEvidencePath = '',
    [string]$RecoveryPlanPath = '',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 1440)]
    [int]$MaxPlanAgeMinutes = 60,

    [switch]$CheckCluster,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc) -and $ExpectedProductionContext -ne 'production-contract') {
    throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
}

$validationArguments = @{
    PlanPath = $PlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ProgressiveEvidencePath'; Value = $ProgressiveEvidencePath }
    [pscustomobject]@{ Name = 'ProgressivePlanPath'; Value = $ProgressivePlanPath }
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'RecoveryEvidencePath'; Value = $RecoveryEvidencePath }
    [pscustomobject]@{ Name = 'RecoveryPlanPath'; Value = $RecoveryPlanPath }
    [pscustomobject]@{ Name = 'ContainmentEvidencePath'; Value = $ContainmentEvidencePath }
    [pscustomobject]@{ Name = 'ResponsePlanPath'; Value = $ResponsePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $validationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-plan.ps1') @validationArguments 6>$null

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

$referenceNow = if ([string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    [DateTimeOffset]::UtcNow
}
else {
    ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$generatedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$planAge = $referenceNow - $generatedAt
if (
    $planAge.TotalMinutes -lt -5 -or
    $planAge.TotalMinutes -gt $MaxPlanAgeMinutes -or
    $referenceNow -gt $expiresAt
) {
    throw "Production recovery second expansion authorization is stale, future-dated, or expired; maximum age is $MaxPlanAgeMinutes minutes."
}
if (
    [string]$plan.readiness.outcome -ne 'passed' -or
    [string]$plan.observation.trafficStability -ne 'stable' -or
    [string]$plan.observation.workloads -ne 'stable' -or
    [string]$plan.observation.errorBudget -ne 'within-budget' -or
    [string]$plan.observation.alerts -ne 'clear' -or
    [string]$plan.observation.functional -ne 'passed' -or
    [string]$plan.observation.dependencies -ne 'healthy' -or
    [string]$plan.observation.operations -ne 'healthy' -or
    [string]$plan.observation.capacity -ne 'healthy' -or
    [string]$plan.observation.security -ne 'clear' -or
    [string]$plan.observation.drift -ne 'clear' -or
    [string]$plan.observation.certificates -ne 'healthy' -or
    [string]$plan.observation.rollbackReadiness -ne 'ready' -or
    [string]$plan.observation.incidentRecord -ne 'updated' -or
    [string]$plan.observation.secondExpansionChange -ne 'approved' -or
    [string]$plan.execution.state -ne 'not-started' -or
    [string]$plan.decision.afterApprovalAction -ne 'execute-approved-recovery-second-expansion-externally'
) {
    throw 'Production recovery second expansion is not authorized; hold the previous recovery boundary and preserve evidence.'
}

Write-Host "Production recovery second expansion gate passed for incident $($plan.incidentId)."
Write-Host "Authorized external boundary: $($plan.traffic.currentPercent)% to $($plan.traffic.targetPercent)%."
Write-Host 'This gate authorizes only the recorded external action; it does not change traffic, prove expansion, or close the incident.'
