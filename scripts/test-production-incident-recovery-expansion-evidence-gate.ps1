[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

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
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence.ps1') @validationArguments 6>$null

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
    throw "Production recovery expansion evidence is stale or future-dated; maximum age is $MaxEvidenceAgeMinutes minutes."
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
    [string]$evidence.verification.expansionChangeRecord -ne 'updated' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [string]$evidence.decision.nextAction -ne 'observe-recovery-expansion-before-next-step'
) {
    throw 'Production recovery expansion execution is not proven; hold or restore the recovery canary and escalate.'
}
if (
    [int]$evidence.traffic.expectedPercent -le [int]$evidence.traffic.recoveryCanaryPercent -or
    [int]$evidence.traffic.expectedPercent -gt 25
) {
    throw 'Recovery expansion evidence must preserve a bounded increase no higher than 25 percent.'
}

Write-Host "Production recovery expansion execution gate passed for incident $($evidence.incidentId)."
Write-Host "Externally enforced recovery expansion target: $($evidence.traffic.observedPercent)%; next action: $($evidence.decision.nextAction)"
Write-Host 'This gate proves only the recorded target; it does not authorize further expansion or close the incident.'
