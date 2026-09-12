[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryProgressiveEvidence {
    param(
        [Parameter(Mandatory)][string]$ProgressivePlanPath,
        [Parameter(Mandatory)][string]$ExpansionEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = -1,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$WorkloadVerificationStatus = 'confirmed',
        [string]$ProgressiveExecutionStatus = 'completed',
        [string]$ErrorBudgetStatus = 'within-budget',
        [string]$AlertStatus = 'clear',
        [string]$FunctionalStatus = 'passed',
        [string]$DependencyStatus = 'healthy',
        [string]$OperationalStatus = 'healthy',
        [string]$CapacityStatus = 'healthy',
        [string]$SecurityStatus = 'clear',
        [string]$DriftStatus = 'clear',
        [string]$CertificateStatus = 'healthy',
        [string]$RollbackReadinessStatus = 'ready',
        [string]$IncidentRecordStatus = 'updated',
        [string]$ProgressiveChangeRecordStatus = 'updated'
    )

    $plan = Get-Content -Raw -LiteralPath $ProgressivePlanPath | ConvertFrom-Json
    if ($ObservedTrafficPercent -lt 0) {
        $ObservedTrafficPercent = [int]$plan.traffic.targetPercent
    }
    $executedAt = $ReferenceTime.ToUniversalTime().AddMinutes(-1)

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-progressive-evidence.ps1') `
        -ProgressivePlanPath $ProgressivePlanPath `
        -ExpansionEvidencePath $ExpansionEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutedAtUtc $executedAt `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -WorkloadVerificationStatus $WorkloadVerificationStatus `
        -ProgressiveExecutionStatus $ProgressiveExecutionStatus `
        -ErrorBudgetStatus $ErrorBudgetStatus `
        -AlertStatus $AlertStatus `
        -FunctionalStatus $FunctionalStatus `
        -DependencyStatus $DependencyStatus `
        -OperationalStatus $OperationalStatus `
        -CapacityStatus $CapacityStatus `
        -SecurityStatus $SecurityStatus `
        -DriftStatus $DriftStatus `
        -CertificateStatus $CertificateStatus `
        -RollbackReadinessStatus $RollbackReadinessStatus `
        -IncidentRecordStatus $IncidentRecordStatus `
        -ProgressiveChangeRecordStatus $ProgressiveChangeRecordStatus `
        -TrafficStateReference ('RECOVERY-PROGRESSIVE-TRAFFIC-' + [string]$plan.incidentId) `
        -WorkloadEvidenceReference ('RECOVERY-PROGRESSIVE-WORKLOAD-' + [string]$plan.incidentId) `
        -ProgressiveExecutionReference ('RECOVERY-PROGRESSIVE-EXECUTION-' + [string]$plan.progressiveChangeId) `
        -ProgressiveGateReference ('RECOVERY-PROGRESSIVE-GATE-' + [string]$plan.progressiveChangeId) `
        -MonitoringEvidenceReference ('RECOVERY-PROGRESSIVE-MONITORING-' + [string]$plan.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-PROGRESSIVE-ROLLBACK-' + [string]$plan.incidentId) `
        -IncidentRecordReference ('RECOVERY-PROGRESSIVE-INCIDENT-' + [string]$plan.incidentId) `
        -ProgressiveChangeRecordReference ('RECOVERY-PROGRESSIVE-CHANGE-' + [string]$plan.progressiveChangeId) `
        -CollectedBy 'Recovery Progressive Evidence Reviewer' `
        -MaxExecutionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'progressive-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-GateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ProgressivePlanPath,
        [Parameter(Mandatory)][string]$ExpansionEvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ProgressivePlanPath $ProgressivePlanPath `
            -ExpansionEvidencePath $ExpansionEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw $FailureMessage
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$progressivePlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-progressive-contract'
$recoveryEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-expansion-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-progressive-evidence-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-contract.ps1') 6>$null

$approvedPlanPath = Join-Path $progressivePlanRoot 'approved/expansion.json'
$canaryEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $recoveryEvidenceRoot 'passed') -Filter 'expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$approvedPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$approvedPlan.approval.approvedAtUtc).ToUniversalTime().AddMinutes(5)

$passedEvidencePath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [int]$passedEvidence.traffic.previousBoundaryPercent -ne 25 -or
    [int]$passedEvidence.traffic.observedPercent -ne 50 -or
    [bool]$passedEvidence.decision.targetReached -ne $true -or
    [int]$passedEvidence.rollback.targetPercent -ne 25 -or
    [int]$passedEvidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$passedEvidence.decision.nextAction -ne 'observe-recovery-progressive-expansion-before-next-step'
) {
    throw 'Passed recovery progressive evidence did not preserve the approved target and rollback boundary.'
}

$pendingPlanPath = Join-Path $testRoot 'pending-plan/expansion.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $pendingPlanPath) -Force | Out-Null
$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json -AsHashtable
$pendingPlan['state'] = 'pending'
$pendingPlan['approval']['status'] = 'pending'
$pendingPlan['approval']['approvedBy'] = $null
$pendingPlan['approval']['approvedAtUtc'] = $null
$pendingPlan['approval']['approvedAtUnixSeconds'] = $null
$pendingPlan['approval']['approvalStatement'] = $null
$pendingPlan['approval']['approvalDigest'] = $null
[System.IO.File]::WriteAllText(
    $pendingPlanPath,
    (($pendingPlan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)
$pendingPlanRejected = $false
try {
    New-TestRecoveryProgressiveEvidence `
        -ProgressivePlanPath $pendingPlanPath `
        -ExpansionEvidencePath $canaryEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'pending-plan-evidence') `
        -ReferenceTime $contractClock | Out-Null
}
catch {
    $pendingPlanRejected = $true
}
if (-not $pendingPlanRejected) {
    throw 'Recovery progressive evidence accepted a plan without explicit approval.'
}

$mismatchedTrafficPath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'traffic-mismatch') `
    -ObservedTrafficPercent 49 `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence.ps1') `
    -EvidencePath $mismatchedTrafficPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
Assert-GateRejected `
    -EvidencePath $mismatchedTrafficPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery progressive expansion execution gate allowed traffic outside the approved target.'

$failedWorkloadPath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'failed-workload') `
    -WorkloadVerificationStatus failed `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $failedWorkloadPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery progressive expansion execution gate allowed failed workload verification.'

$unknownTrafficPath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown-traffic') `
    -TrafficEnforcementStatus unknown `
    -ReferenceTime $contractClock
$unknownTrafficEvidence = Get-Content -Raw -LiteralPath $unknownTrafficPath | ConvertFrom-Json
if ([bool]$unknownTrafficEvidence.traffic.externallyEnforced) {
    throw 'Unknown recovery progressive expansion traffic enforcement was incorrectly recorded as externally enforced.'
}
Assert-GateRejected `
    -EvidencePath $unknownTrafficPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery progressive expansion execution gate allowed unknown traffic enforcement.'

$exhaustedBudgetPath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'exhausted-budget') `
    -ErrorBudgetStatus exhausted `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $exhaustedBudgetPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery progressive expansion execution gate allowed an exhausted error budget.'

$rollbackNotReadyPath = New-TestRecoveryProgressiveEvidence `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'rollback-not-ready') `
    -RollbackReadinessStatus not-ready `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $rollbackNotReadyPath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery progressive expansion execution gate allowed an unavailable rollback path.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['trafficStateReference'] = 'TAMPERED-RECOVERY-PROGRESSIVE-TRAFFIC'
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -ProgressivePlanPath $approvedPlanPath `
            -ExpansionEvidencePath $canaryEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The recovery progressive expansion execution gate allowed tampered evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($approvedPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -ProgressivePlanPath $approvedPlanPath `
            -ExpansionEvidencePath $canaryEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }
    catch {
        $approvedPlanTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($approvedPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $approvedPlanTamperingRejected) {
    throw 'The recovery progressive expansion execution gate allowed a changed approved progressive plan.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ProgressivePlanPath $approvedPlanPath `
    -ExpansionEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery progressive expansion execution evidence contract passed.'
