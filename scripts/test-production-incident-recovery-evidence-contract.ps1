[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryEvidence {
    param(
        [Parameter(Mandatory)][string]$RecoveryPlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][int]$ObservedTrafficPercent,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$WorkloadVerificationStatus = 'confirmed',
        [string]$RecoveryExecutionStatus = 'completed',
        [string]$FunctionalStatus = 'passed',
        [string]$DependencyStatus = 'healthy',
        [string]$OperationalStatus = 'healthy',
        [string]$CapacityStatus = 'healthy',
        [string]$SecurityStatus = 'clear',
        [string]$DriftStatus = 'clear',
        [string]$CertificateStatus = 'healthy',
        [string]$RollbackReadinessStatus = 'ready',
        [string]$IncidentRecordStatus = 'updated',
        [string]$RecoveryChangeRecordStatus = 'updated'
    )

    $plan = Get-Content -Raw -LiteralPath $RecoveryPlanPath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-evidence.ps1') `
        -RecoveryPlanPath $RecoveryPlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutedAtUtc ([DateTimeOffset]::UtcNow) `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -WorkloadVerificationStatus $WorkloadVerificationStatus `
        -RecoveryExecutionStatus $RecoveryExecutionStatus `
        -FunctionalStatus $FunctionalStatus `
        -DependencyStatus $DependencyStatus `
        -OperationalStatus $OperationalStatus `
        -CapacityStatus $CapacityStatus `
        -SecurityStatus $SecurityStatus `
        -DriftStatus $DriftStatus `
        -CertificateStatus $CertificateStatus `
        -RollbackReadinessStatus $RollbackReadinessStatus `
        -IncidentRecordStatus $IncidentRecordStatus `
        -RecoveryChangeRecordStatus $RecoveryChangeRecordStatus `
        -TrafficStateReference ("TRAFFIC-EXECUTION-" + [string]$plan.incidentId) `
        -WorkloadEvidenceReference ("WORKLOAD-RECOVERY-" + [string]$plan.incidentId) `
        -RecoveryExecutionReference ("RECOVERY-EXECUTION-" + [string]$plan.recoveryChangeId) `
        -RecoveryGateReference ("RECOVERY-GATE-" + [string]$plan.recoveryChangeId) `
        -MonitoringEvidenceReference ("MONITORING-RECOVERY-" + [string]$plan.incidentId) `
        -RollbackEvidenceReference ("ROLLBACK-READY-" + [string]$plan.incidentId) `
        -IncidentRecordReference ("INCIDENT-RECOVERED-" + [string]$plan.incidentId) `
        -RecoveryChangeRecordReference ("CHANGE-COMPLETED-" + [string]$plan.recoveryChangeId) `
        -CollectedBy 'Recovery Evidence Reviewer' `
        -MaxExecutionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'recovery-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-GateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw $FailureMessage
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$recoveryPlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-evidence-contract'

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-contract.ps1') 6>$null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$zeroRecoveryPlanPath = Join-Path $recoveryPlanRoot 'zero-to-canary/recovery.json'
$rollbackRecoveryPlanPath = Join-Path $recoveryPlanRoot 'seventy-five-to-full/recovery.json'
$holdRecoveryPlanPath = Join-Path $recoveryPlanRoot 'hold-at-full/recovery.json'
$pendingRecoveryPlanPath = Join-Path $recoveryPlanRoot 'approval-mismatch/recovery.json'
$blockedRecoveryPlanPath = Join-Path $recoveryPlanRoot 'failed-remediation/recovery.json'

$zeroEvidencePath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $zeroRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'zero-to-canary') `
    -ObservedTrafficPercent 1
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
    -EvidencePath $zeroEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$zeroEvidence = Get-Content -Raw -LiteralPath $zeroEvidencePath | ConvertFrom-Json
if (
    [int]$zeroEvidence.traffic.containedPercent -ne 0 -or
    [int]$zeroEvidence.traffic.observedPercent -ne 1 -or
    [bool]$zeroEvidence.decision.targetReached -ne $true -or
    [bool]$zeroEvidence.decision.fullTrafficRestored -ne $false -or
    [string]$zeroEvidence.decision.nextAction -ne 'observe-recovery-canary-before-expansion'
) {
    throw 'The zero-to-canary execution evidence did not preserve its bounded recovery decision.'
}

$rollbackEvidencePath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $rollbackRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'seventy-five-to-full') `
    -ObservedTrafficPercent 100
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
    -EvidencePath $rollbackEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$rollbackEvidence = Get-Content -Raw -LiteralPath $rollbackEvidencePath | ConvertFrom-Json
if (
    [int]$rollbackEvidence.traffic.containedPercent -ne 75 -or
    [int]$rollbackEvidence.traffic.observedPercent -ne 100 -or
    [int]$rollbackEvidence.rollback.targetPercent -ne 75 -or
    [bool]$rollbackEvidence.decision.fullTrafficRestored -ne $true -or
    [string]$rollbackEvidence.decision.nextAction -ne 'resume-continuous-production-assurance'
) {
    throw 'The 75-to-100 execution evidence did not preserve full-traffic recovery and rollback.'
}

$holdEvidencePath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $holdRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'hold-at-full') `
    -ObservedTrafficPercent 100
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
    -EvidencePath $holdEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$holdEvidence = Get-Content -Raw -LiteralPath $holdEvidencePath | ConvertFrom-Json
if (
    [int]$holdEvidence.traffic.containedPercent -ne 100 -or
    [int]$holdEvidence.traffic.observedPercent -ne 100 -or
    [bool]$holdEvidence.decision.fullTrafficRestored -ne $true
) {
    throw 'The 100 percent hold execution evidence did not preserve the approved resumption boundary.'
}

$pendingPlanRejected = $false
try {
    New-TestRecoveryEvidence `
        -RecoveryPlanPath $pendingRecoveryPlanPath `
        -OutputDirectory (Join-Path $testRoot 'pending-plan') `
        -ObservedTrafficPercent 1 | Out-Null
}
catch {
    $pendingPlanRejected = $true
}
if (-not $pendingPlanRejected) {
    throw 'Recovery execution evidence accepted a plan without explicit approval.'
}

$blockedPlanRejected = $false
try {
    New-TestRecoveryEvidence `
        -RecoveryPlanPath $blockedRecoveryPlanPath `
        -OutputDirectory (Join-Path $testRoot 'blocked-plan') `
        -ObservedTrafficPercent 1 | Out-Null
}
catch {
    $blockedPlanRejected = $true
}
if (-not $blockedPlanRejected) {
    throw 'Recovery execution evidence accepted a blocked recovery plan.'
}

$mismatchedTrafficPath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $zeroRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'traffic-mismatch') `
    -ObservedTrafficPercent 2
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') `
    -EvidencePath $mismatchedTrafficPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Assert-GateRejected `
    -EvidencePath $mismatchedTrafficPath `
    -FailureMessage 'The recovery execution gate allowed traffic outside the approved target.'

$failedWorkloadPath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $zeroRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'failed-workload') `
    -ObservedTrafficPercent 1 `
    -WorkloadVerificationStatus failed
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') `
    -EvidencePath $failedWorkloadPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Assert-GateRejected `
    -EvidencePath $failedWorkloadPath `
    -FailureMessage 'The recovery execution gate allowed failed workload verification.'

$unknownTrafficPath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $zeroRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-traffic') `
    -ObservedTrafficPercent 1 `
    -TrafficEnforcementStatus unknown
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') `
    -EvidencePath $unknownTrafficPath `
    -ExpectedProductionContext 'production-contract' 6>$null
$unknownTrafficEvidence = Get-Content -Raw -LiteralPath $unknownTrafficPath | ConvertFrom-Json
if ([bool]$unknownTrafficEvidence.traffic.externallyEnforced) {
    throw 'Unknown recovery traffic enforcement was incorrectly recorded as externally enforced.'
}
Assert-GateRejected `
    -EvidencePath $unknownTrafficPath `
    -FailureMessage 'The recovery execution gate allowed unknown traffic enforcement.'

$rollbackNotReadyPath = New-TestRecoveryEvidence `
    -RecoveryPlanPath $rollbackRecoveryPlanPath `
    -OutputDirectory (Join-Path $testRoot 'rollback-not-ready') `
    -ObservedTrafficPercent 100 `
    -RollbackReadinessStatus not-ready
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') `
    -EvidencePath $rollbackNotReadyPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Assert-GateRejected `
    -EvidencePath $rollbackNotReadyPath `
    -FailureMessage 'The recovery execution gate allowed an unavailable rollback path.'

$originalEvidence = [System.IO.File]::ReadAllText($zeroEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['trafficStateReference'] = 'TAMPERED-RECOVERY-TRAFFIC'
    [System.IO.File]::WriteAllText(
        $zeroEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
            -EvidencePath $zeroEvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($zeroEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The recovery execution gate allowed tampered execution evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($zeroRecoveryPlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($zeroRecoveryPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
            -EvidencePath $zeroEvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $approvedPlanTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($zeroRecoveryPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $approvedPlanTamperingRejected) {
    throw 'The recovery execution gate allowed a changed approved recovery plan.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-gate.ps1') `
    -EvidencePath $zeroEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
Write-Host 'Production incident recovery execution evidence contract passed.'
