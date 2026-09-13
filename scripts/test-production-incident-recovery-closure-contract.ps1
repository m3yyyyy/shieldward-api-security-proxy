[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryClosurePlan {
    param(
        [Parameter(Mandatory)][string]$FinalExpansionEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ClosureChangeId,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$HoldTrafficPercent = 100,
        [int]$ObservedTrafficPercent = -1,
        [string]$TrafficStabilityStatus = 'stable',
        [string]$WorkloadStatus = 'stable',
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
        [string]$ReacceptanceStatus = 'passed',
        [string]$IncidentRecordStatus = 'updated',
        [string]$ClosureChangeStatus = 'approved',
        [Nullable[DateTimeOffset]]$ObservationStartedAt = $null,
        [Nullable[DateTimeOffset]]$ObservationEndedAt = $null
    )

    $evidence = Get-Content -Raw -LiteralPath $FinalExpansionEvidencePath | ConvertFrom-Json
    if ($ObservedTrafficPercent -lt 0) {
        $ObservedTrafficPercent = [int]$evidence.traffic.observedPercent
    }
    $start = if ($null -eq $ObservationStartedAt) {
        ([DateTimeOffset]$evidence.execution.executedAtUtc).ToUniversalTime()
    }
    else {
        $ObservationStartedAt.Value.ToUniversalTime()
    }
    $end = if ($null -eq $ObservationEndedAt) {
        $ReferenceTime.ToUniversalTime()
    }
    else {
        $ObservationEndedAt.Value.ToUniversalTime()
    }

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-closure-plan.ps1') `
        -FinalExpansionEvidencePath $FinalExpansionEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ClosureChangeId $ClosureChangeId `
        -ApprovalOwner 'Recovery Incident Closure Owner' `
        -HoldTrafficPercent $HoldTrafficPercent `
        -ObservationStartedAtUtc $start `
        -ObservationEndedAtUtc $end `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficStabilityStatus $TrafficStabilityStatus `
        -WorkloadStatus $WorkloadStatus `
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
        -ReacceptanceStatus $ReacceptanceStatus `
        -IncidentRecordStatus $IncidentRecordStatus `
        -ClosureChangeStatus $ClosureChangeStatus `
        -PreviousExecutionGateReference ('RECOVERY-FINAL-EXPANSION-EXECUTION-GATE-' + [string]$evidence.finalExpansionChangeId) `
        -TrafficObservationReference ('RECOVERY-INCIDENT-CLOSURE-TRAFFIC-' + [string]$evidence.incidentId) `
        -MonitoringEvidenceReference ('RECOVERY-INCIDENT-CLOSURE-MONITORING-' + [string]$evidence.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-INCIDENT-CLOSURE-ROLLBACK-' + [string]$evidence.incidentId) `
        -ReacceptanceEvidenceReference ('RECOVERY-INCIDENT-CLOSURE-REACCEPTANCE-' + [string]$evidence.incidentId) `
        -IncidentRecordReference ('INCIDENT-RECOVERY-INCIDENT-CLOSURE-' + [string]$evidence.incidentId) `
        -ClosureChangeReference ('CHANGE-' + $ClosureChangeId) `
        -ReviewedBy 'Independent Recovery Closure Reviewer' `
        -ObservationMinutes 15 `
        -MaxFinalExpansionEvidenceAgeMinutes 60 `
        -PlanValidityMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Join-Path $OutputDirectory 'closure.json')
}

function Assert-PlanRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & $Action
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw $FailureMessage
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$expansionEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-final-expansion-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence-contract.ps1') 6>$null

$passedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'passed') -Filter 'final-expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'failed-workload') -Filter 'final-expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$passedEvidence.collectedAtUtc).ToUniversalTime().AddMinutes(20)

$approvedPlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-001' `
    -ReferenceTime $contractClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
if (
    [int]$pendingPlan.traffic.currentPercent -ne 100 -or
    [int]$pendingPlan.traffic.holdPercent -ne 100 -or
    [int]$pendingPlan.traffic.trafficMutationPercentagePoints -ne 0 -or
    [int]$pendingPlan.rollback.targetPercent -ne 75 -or
    [int]$pendingPlan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$pendingPlan.observation.reacceptance -ne 'passed' -or
    [string]$pendingPlan.readiness.outcome -ne 'passed' -or
    [string]$pendingPlan.decision.nextAction -ne 'await-independent-recovery-incident-closure-approval'
) {
    throw 'Healthy final-expansion evidence and independent reacceptance did not produce a no-mutation incident-closure plan at 100 percent.'
}

Assert-PlanRejected `
    -FailureMessage 'The recovery incident closure contract accepted an invalid approval statement.' `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-closure-plan.ps1') `
            -PlanPath $approvedPlanPath `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy 'Recovery Incident Closure Owner' `
            -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

& (Join-Path $PSScriptRoot 'approve-production-incident-recovery-closure-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Recovery Incident Closure Owner' `
    -ApprovalStatement ([string]$pendingPlan.approval.requiredStatement) `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Assert-PlanRejected `
    -FailureMessage 'Incident-closure planning accepted failed final expansion execution evidence.' `
    -Action {
        New-TestRecoveryClosurePlan `
            -FinalExpansionEvidencePath $failedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'failed-evidence') `
            -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-FAILED' `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Incident-closure planning accepted a hold boundary other than 100 percent.' `
    -Action {
        New-TestRecoveryClosurePlan `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'oversized-target') `
            -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-LARGE' `
            -HoldTrafficPercent 99 `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Incident-closure planning accepted traffic outside the proven 100 percent boundary.' `
    -Action {
        New-TestRecoveryClosurePlan `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-observation') `
            -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-MISMATCH' `
            -ObservedTrafficPercent 99 `
            -ReferenceTime $contractClock | Out-Null
    }

$degradedPlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'degraded') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-DEGRADED' `
    -OperationalStatus degraded `
    -ReferenceTime $contractClock
$degradedPlan = Get-Content -Raw -LiteralPath $degradedPlanPath | ConvertFrom-Json
if (
    [string]$degradedPlan.state -ne 'blocked' -or
    [string]$degradedPlan.readiness.outcome -ne 'failed' -or
    [string]$degradedPlan.decision.nextAction -ne 'restore-previous-recovery-boundary-and-escalate'
) {
    throw 'Degraded recovery incident closure boundary observation did not remain blocked.'
}
Assert-PlanRejected `
    -FailureMessage 'The recovery incident closure gate allowed degraded observation evidence.' `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-gate.ps1') `
            -PlanPath $degradedPlanPath `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

$unknownPlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-UNKNOWN' `
    -SecurityStatus unknown `
    -ReferenceTime $contractClock
$unknownPlan = Get-Content -Raw -LiteralPath $unknownPlanPath | ConvertFrom-Json
if (
    [string]$unknownPlan.state -ne 'blocked' -or
    [string]$unknownPlan.readiness.outcome -ne 'unknown' -or
    [string]$unknownPlan.decision.nextAction -ne 'hold-recovery-boundary-and-collect-evidence'
) {
    throw 'Unknown recovery incident closure boundary observation did not fail closed.'
}

$pendingChangePlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-PENDING' `
    -ClosureChangeStatus pending `
    -ReferenceTime $contractClock
$pendingChangePlan = Get-Content -Raw -LiteralPath $pendingChangePlanPath | ConvertFrom-Json
if ([string]$pendingChangePlan.state -ne 'blocked' -or [string]$pendingChangePlan.readiness.outcome -ne 'unknown') {
    throw 'A pending external recovery incident closure change did not fail closed.'
}

$failedReacceptancePlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'failed-reacceptance') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-REACCEPTANCE' `
    -ReacceptanceStatus failed `
    -ReferenceTime $contractClock
$failedReacceptancePlan = Get-Content -Raw -LiteralPath $failedReacceptancePlanPath | ConvertFrom-Json
if ([string]$failedReacceptancePlan.state -ne 'blocked' -or [string]$failedReacceptancePlan.readiness.outcome -ne 'failed') {
    throw 'Failed independent production reacceptance did not block incident closure.'
}

$unknownReacceptancePlanPath = New-TestRecoveryClosurePlan `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown-reacceptance') `
    -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-REACCEPTANCE-UNKNOWN' `
    -ReacceptanceStatus unknown `
    -ReferenceTime $contractClock
$unknownReacceptancePlan = Get-Content -Raw -LiteralPath $unknownReacceptancePlanPath | ConvertFrom-Json
if ([string]$unknownReacceptancePlan.state -ne 'blocked' -or [string]$unknownReacceptancePlan.readiness.outcome -ne 'unknown') {
    throw 'Unknown independent production reacceptance did not fail closed.'
}

Assert-PlanRejected `
    -FailureMessage 'Recovery incident-closure planning accepted an incomplete observation window.' `
    -Action {
        New-TestRecoveryClosurePlan `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'short-observation') `
            -ClosureChangeId 'CHG-TEST-RECOVERY-INCIDENT-CLOSURE-SHORT' `
            -ObservationStartedAt $contractClock.AddMinutes(-5) `
            -ObservationEndedAt $contractClock `
            -ReferenceTime $contractClock | Out-Null
    }

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['holdPercent'] = 99
    [System.IO.File]::WriteAllText(
        $approvedPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -FinalExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }
    catch {
        $planTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($approvedPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) {
    throw 'The recovery incident closure gate allowed a tampered approved plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -FinalExpansionEvidencePath $passedEvidencePath `
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
    throw 'The recovery incident closure gate allowed changed final expansion execution evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -FinalExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery incident closure observation and planning contract passed.'
