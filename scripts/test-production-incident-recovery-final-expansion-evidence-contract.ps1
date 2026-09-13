[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryFinalExpansionEvidence {
    param(
        [Parameter(Mandatory)][string]$FinalExpansionPlanPath,
        [Parameter(Mandatory)][string]$SecondExpansionEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = -1,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$WorkloadVerificationStatus = 'confirmed',
        [string]$FinalExpansionExecutionStatus = 'completed',
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
        [string]$FinalExpansionChangeRecordStatus = 'updated'
    )

    $plan = Get-Content -Raw -LiteralPath $FinalExpansionPlanPath | ConvertFrom-Json
    if ($ObservedTrafficPercent -lt 0) {
        $ObservedTrafficPercent = [int]$plan.traffic.targetPercent
    }
    $executedAt = $ReferenceTime.ToUniversalTime().AddMinutes(-1)

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-final-expansion-evidence.ps1') `
        -FinalExpansionPlanPath $FinalExpansionPlanPath `
        -SecondExpansionEvidencePath $SecondExpansionEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutedAtUtc $executedAt `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -WorkloadVerificationStatus $WorkloadVerificationStatus `
        -FinalExpansionExecutionStatus $FinalExpansionExecutionStatus `
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
        -FinalExpansionChangeRecordStatus $FinalExpansionChangeRecordStatus `
        -TrafficStateReference ('RECOVERY-FINAL-EXPANSION-TRAFFIC-' + [string]$plan.incidentId) `
        -WorkloadEvidenceReference ('RECOVERY-FINAL-EXPANSION-WORKLOAD-' + [string]$plan.incidentId) `
        -FinalExpansionExecutionReference ('RECOVERY-FINAL-EXPANSION-EXECUTION-' + [string]$plan.finalExpansionChangeId) `
        -FinalExpansionGateReference ('RECOVERY-FINAL-EXPANSION-GATE-' + [string]$plan.finalExpansionChangeId) `
        -MonitoringEvidenceReference ('RECOVERY-FINAL-EXPANSION-MONITORING-' + [string]$plan.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-FINAL-EXPANSION-ROLLBACK-' + [string]$plan.incidentId) `
        -IncidentRecordReference ('RECOVERY-FINAL-EXPANSION-INCIDENT-' + [string]$plan.incidentId) `
        -FinalExpansionChangeRecordReference ('RECOVERY-FINAL-EXPANSION-CHANGE-' + [string]$plan.finalExpansionChangeId) `
        -CollectedBy 'Recovery Second Expansion Evidence Reviewer' `
        -MaxExecutionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'final-expansion-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-GateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$FinalExpansionPlanPath,
        [Parameter(Mandatory)][string]$SecondExpansionEvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-gate.ps1') `
            -EvidencePath $EvidencePath `
            -FinalExpansionPlanPath $FinalExpansionPlanPath `
            -SecondExpansionEvidencePath $SecondExpansionEvidencePath `
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
$finalExpansionPlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-final-expansion-contract'
$secondExpansionEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-second-expansion-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-final-expansion-evidence-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-contract.ps1') 6>$null

$approvedPlanPath = Join-Path $finalExpansionPlanRoot 'approved/expansion.json'
$secondExpansionEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $secondExpansionEvidenceRoot 'passed') -Filter 'second-expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$approvedPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$approvedPlan.approval.approvedAtUtc).ToUniversalTime().AddMinutes(5)

$passedEvidencePath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [int]$passedEvidence.traffic.previousBoundaryPercent -ne 75 -or
    [int]$passedEvidence.traffic.observedPercent -ne 100 -or
    [bool]$passedEvidence.decision.targetReached -ne $true -or
    [int]$passedEvidence.rollback.targetPercent -ne 75 -or
    [int]$passedEvidence.rollback.emergencyTargetPercent -ne 0 -or
    [string]$passedEvidence.decision.nextAction -ne 'begin-independent-recovery-acceptance-and-incident-closure-review'
) {
    throw 'Passed recovery final expansion evidence did not preserve the approved target and rollback boundary.'
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
    New-TestRecoveryFinalExpansionEvidence `
        -FinalExpansionPlanPath $pendingPlanPath `
        -SecondExpansionEvidencePath $secondExpansionEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'pending-plan-evidence') `
        -ReferenceTime $contractClock | Out-Null
}
catch {
    $pendingPlanRejected = $true
}
if (-not $pendingPlanRejected) {
    throw 'Recovery final expansion evidence accepted a plan without explicit approval.'
}

$mismatchedTrafficPath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'traffic-mismatch') `
    -ObservedTrafficPercent 99 `
    -ReferenceTime $contractClock
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence.ps1') `
    -EvidencePath $mismatchedTrafficPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
Assert-GateRejected `
    -EvidencePath $mismatchedTrafficPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery final expansion execution gate allowed traffic outside the approved target.'

$failedWorkloadPath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'failed-workload') `
    -WorkloadVerificationStatus failed `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $failedWorkloadPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery final expansion execution gate allowed failed workload verification.'

$unknownTrafficPath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown-traffic') `
    -TrafficEnforcementStatus unknown `
    -ReferenceTime $contractClock
$unknownTrafficEvidence = Get-Content -Raw -LiteralPath $unknownTrafficPath | ConvertFrom-Json
if ([bool]$unknownTrafficEvidence.traffic.externallyEnforced) {
    throw 'Unknown recovery final expansion traffic enforcement was incorrectly recorded as externally enforced.'
}
Assert-GateRejected `
    -EvidencePath $unknownTrafficPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery final expansion execution gate allowed unknown traffic enforcement.'

$exhaustedBudgetPath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'exhausted-budget') `
    -ErrorBudgetStatus exhausted `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $exhaustedBudgetPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery final expansion execution gate allowed an exhausted error budget.'

$rollbackNotReadyPath = New-TestRecoveryFinalExpansionEvidence `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'rollback-not-ready') `
    -RollbackReadinessStatus not-ready `
    -ReferenceTime $contractClock
Assert-GateRejected `
    -EvidencePath $rollbackNotReadyPath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ReferenceTime $contractClock `
    -FailureMessage 'The recovery final expansion execution gate allowed an unavailable rollback path.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['trafficStateReference'] = 'TAMPERED-RECOVERY-FINAL-EXPANSION-TRAFFIC'
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -FinalExpansionPlanPath $approvedPlanPath `
            -SecondExpansionEvidencePath $secondExpansionEvidencePath `
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
    throw 'The recovery final expansion execution gate allowed tampered evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($approvedPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-gate.ps1') `
            -EvidencePath $passedEvidencePath `
            -FinalExpansionPlanPath $approvedPlanPath `
            -SecondExpansionEvidencePath $secondExpansionEvidencePath `
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
    throw 'The recovery final expansion execution gate allowed a changed approved final expansion plan.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -FinalExpansionPlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $secondExpansionEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery final expansion execution evidence contract passed.'
