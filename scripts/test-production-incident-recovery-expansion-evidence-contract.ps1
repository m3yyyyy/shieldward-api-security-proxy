[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryExpansionEvidence {
    param(
        [Parameter(Mandatory)][string]$ExpansionPlanPath,
        [Parameter(Mandatory)][string]$RecoveryEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = -1,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$WorkloadVerificationStatus = 'confirmed',
        [string]$ExpansionExecutionStatus = 'completed',
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
        [string]$ExpansionChangeRecordStatus = 'updated'
    )

    $plan = Get-Content -Raw -LiteralPath $ExpansionPlanPath | ConvertFrom-Json
    if ($ObservedTrafficPercent -lt 0) {
        $ObservedTrafficPercent = [int]$plan.traffic.targetPercent
    }
    $executedAt = $ReferenceTime.ToUniversalTime().AddMinutes(-1)

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-expansion-evidence.ps1') `
        -ExpansionPlanPath $ExpansionPlanPath `
        -RecoveryEvidencePath $RecoveryEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutedAtUtc $executedAt `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -WorkloadVerificationStatus $WorkloadVerificationStatus `
        -ExpansionExecutionStatus $ExpansionExecutionStatus `
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
        -ExpansionChangeRecordStatus $ExpansionChangeRecordStatus `
        -TrafficStateReference ('RECOVERY-EXPANSION-TRAFFIC-' + [string]$plan.incidentId) `
        -WorkloadEvidenceReference ('RECOVERY-EXPANSION-WORKLOAD-' + [string]$plan.incidentId) `
        -ExpansionExecutionReference ('RECOVERY-EXPANSION-EXECUTION-' + [string]$plan.expansionChangeId) `
        -ExpansionGateReference ('RECOVERY-EXPANSION-GATE-' + [string]$plan.expansionChangeId) `
        -MonitoringEvidenceReference ('RECOVERY-EXPANSION-MONITORING-' + [string]$plan.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-EXPANSION-ROLLBACK-' + [string]$plan.incidentId) `
        -IncidentRecordReference ('RECOVERY-EXPANSION-INCIDENT-' + [string]$plan.incidentId) `
        -ExpansionChangeRecordReference ('RECOVERY-EXPANSION-CHANGE-' + [string]$plan.expansionChangeId) `
        -CollectedBy 'Recovery Expansion Evidence Reviewer' `
        -MaxExecutionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'expansion-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-GateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ExpansionPlanPath,
        [Parameter(Mandatory)][string]$RecoveryEvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ExpansionPlanPath $ExpansionPlanPath `
            -RecoveryEvidencePath $RecoveryEvidencePath `
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
$expansionPlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-expansion-contract'
$recoveryEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-expansion-evidence-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-contract.ps1') 6>$null

$approvedPlanPath = Join-Path $expansionPlanRoot 'approved/expansion.json'
$canaryEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $recoveryEvidenceRoot 'zero-to-canary') -Filter 'recovery-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$approvedPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$approvedPlan.approval.approvedAtUtc).ToUniversalTime().AddMinutes(5)

$passedEvidencePath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [int]$passedEvidence.traffic.recoveryCanaryPercent -ne 1 -or
    [int]$passedEvidence.traffic.observedPercent -ne 25 -or
    [bool]$passedEvidence.decision.targetReached -ne $true -or
    [int]$passedEvidence.rollback.targetPercent -ne 1 -or
    [int]$passedEvidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$passedEvidence.decision.nextAction -ne 'observe-recovery-expansion-before-next-step'
) {
    throw 'Passed recovery expansion evidence did not preserve the approved target and rollback boundary.'
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
    New-TestRecoveryExpansionEvidence `
        -ExpansionPlanPath $pendingPlanPath `
        -RecoveryEvidencePath $canaryEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'pending-plan-evidence') `
        -ReferenceTime $contractClock | Out-Null
}
catch {
    $pendingPlanRejected = $true
}
if (-not $pendingPlanRejected) {
    throw 'Recovery expansion evidence accepted a plan without explicit approval.'
}

$mismatchedTrafficPath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'traffic-mismatch') `
    -ObservedTrafficPercent 24 `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence.ps1') `
    -EvidencePath $mismatchedTrafficPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
Assert-GateRejected `
    -EvidencePath $mismatchedTrafficPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery expansion execution gate allowed traffic outside the approved target.'

$failedWorkloadPath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'failed-workload') `
    -WorkloadVerificationStatus failed `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $failedWorkloadPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery expansion execution gate allowed failed workload verification.'

$unknownTrafficPath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown-traffic') `
    -TrafficEnforcementStatus unknown `
    -ReferenceTime $contractClock
$unknownTrafficEvidence = Get-Content -Raw -LiteralPath $unknownTrafficPath | ConvertFrom-Json
if ([bool]$unknownTrafficEvidence.traffic.externallyEnforced) {
    throw 'Unknown recovery expansion traffic enforcement was incorrectly recorded as externally enforced.'
}
Assert-GateRejected `
    -EvidencePath $unknownTrafficPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery expansion execution gate allowed unknown traffic enforcement.'

$exhaustedBudgetPath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'exhausted-budget') `
    -ErrorBudgetStatus exhausted `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $exhaustedBudgetPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery expansion execution gate allowed an exhausted error budget.'

$rollbackNotReadyPath = New-TestRecoveryExpansionEvidence `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'rollback-not-ready') `
    -RollbackReadinessStatus not-ready `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $rollbackNotReadyPath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery expansion execution gate allowed an unavailable rollback path.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['trafficStateReference'] = 'TAMPERED-RECOVERY-EXPANSION-TRAFFIC'
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -ExpansionPlanPath $approvedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
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
    throw 'The recovery expansion execution gate allowed tampered evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($approvedPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -ExpansionPlanPath $approvedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
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
    throw 'The recovery expansion execution gate allowed a changed approved expansion plan.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ExpansionPlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery expansion execution evidence contract passed.'
