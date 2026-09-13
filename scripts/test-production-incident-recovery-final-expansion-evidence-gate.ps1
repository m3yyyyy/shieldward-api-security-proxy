[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$FinalExpansionPlanPath = '',
    [string]$SecondExpansionEvidencePath = '',
    [string]$SecondExpansionPlanPath = '',
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
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'FinalExpansionPlanPath'; Value = $FinalExpansionPlanPath }
    [pscustomobject]@{ Name = 'SecondExpansionEvidencePath'; Value = $SecondExpansionEvidencePath }
    [pscustomobject]@{ Name = 'SecondExpansionPlanPath'; Value = $SecondExpansionPlanPath }
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
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence.ps1') @validationArguments 6>$null

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
if ($evidenceAge.TotalMinutes -lt -5 -or $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes) {
    throw "Production recovery final expansion evidence is stale or future-dated; maximum age is $MaxEvidenceAgeMinutes minutes."
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.execution.status -ne 'completed' -or
    [bool]$evidence.traffic.matchesPlan -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [bool]$evidence.traffic.externallyEnforced -ne $true -or
    [string]$evidence.verification.workloads -ne 'confirmed' -or
    [string]$evidence.verification.errorBudget -ne 'within-budget' -or
    [string]$evidence.verification.alerts -ne 'clear' -or
    [string]$evidence.verification.functional -ne 'passed' -or
    [string]$evidence.verification.dependencies -ne 'healthy' -or
    [string]$evidence.verification.operations -ne 'healthy' -or
    [string]$evidence.verification.capacity -ne 'healthy' -or
    [string]$evidence.verification.security -ne 'clear' -or
    [string]$evidence.verification.drift -ne 'clear' -or
    [string]$evidence.verification.certificates -ne 'healthy' -or
    [string]$evidence.verification.rollbackReadiness -ne 'ready' -or
    [string]$evidence.verification.incidentRecord -ne 'updated' -or
    [string]$evidence.verification.finalExpansionChangeRecord -ne 'updated' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [string]$evidence.decision.nextAction -ne 'begin-independent-recovery-acceptance-and-incident-closure-review'
) {
    throw 'Production recovery final expansion execution is not proven; hold or restore the previous recovery boundary and escalate.'
}
if (
    [int]$evidence.traffic.previousBoundaryPercent -ne 75 -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [int]$evidence.traffic.observedPercent -ne 100 -or
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0
) {
    throw 'Recovery final expansion evidence must prove the exact 75-to-100-percent boundary while preserving rollback to 75 percent and emergency disable-to-zero.'
}

Write-Host "Production recovery final expansion execution gate passed for incident $($evidence.incidentId)."
Write-Host "Externally enforced recovery final expansion target: $($evidence.traffic.observedPercent)%; next action: $($evidence.decision.nextAction)"
Write-Host 'This gate proves only the recorded target; it does not authorize further expansion or close the incident.'
