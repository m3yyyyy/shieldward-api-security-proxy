[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryFinalExpansionPlan {
    param(
        [Parameter(Mandatory)][string]$SecondExpansionEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$FinalExpansionChangeId,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$TargetPercent = 100,
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
        [string]$IncidentRecordStatus = 'updated',
        [string]$FinalExpansionChangeStatus = 'approved',
        [Nullable[DateTimeOffset]]$ObservationStartedAt = $null,
        [Nullable[DateTimeOffset]]$ObservationEndedAt = $null
    )

    $evidence = Get-Content -Raw -LiteralPath $SecondExpansionEvidencePath | ConvertFrom-Json
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

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-final-expansion-plan.ps1') `
        -SecondExpansionEvidencePath $SecondExpansionEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -FinalExpansionChangeId $FinalExpansionChangeId `
        -ApprovalOwner 'Recovery Second Expansion Owner' `
        -TargetPercent $TargetPercent `
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
        -IncidentRecordStatus $IncidentRecordStatus `
        -FinalExpansionChangeStatus $FinalExpansionChangeStatus `
        -PreviousExecutionGateReference ('RECOVERY-PROGRESSIVE-EXECUTION-GATE-' + [string]$evidence.progressiveChangeId) `
        -TrafficObservationReference ('RECOVERY-FINAL-EXPANSION-TRAFFIC-' + [string]$evidence.incidentId) `
        -MonitoringEvidenceReference ('RECOVERY-FINAL-EXPANSION-MONITORING-' + [string]$evidence.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-FINAL-EXPANSION-ROLLBACK-' + [string]$evidence.incidentId) `
        -IncidentRecordReference ('INCIDENT-RECOVERY-FINAL-EXPANSION-' + [string]$evidence.incidentId) `
        -FinalExpansionChangeReference ('CHANGE-' + $FinalExpansionChangeId) `
        -ReviewedBy 'Recovery Second Expansion Reviewer' `
        -ObservationMinutes 15 `
        -MaxSecondExpansionEvidenceAgeMinutes 60 `
        -PlanValidityMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Join-Path $OutputDirectory 'expansion.json')
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
$expansionEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-second-expansion-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-final-expansion-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-evidence-contract.ps1') 6>$null

$passedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'passed') -Filter 'second-expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'failed-workload') -Filter 'second-expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$passedEvidence.collectedAtUtc).ToUniversalTime().AddMinutes(20)

$approvedPlanPath = New-TestRecoveryFinalExpansionPlan `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-001' `
    -ReferenceTime $contractClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
if (
    [int]$pendingPlan.traffic.currentPercent -ne 75 -or
    [int]$pendingPlan.traffic.targetPercent -ne 100 -or
    [int]$pendingPlan.rollback.targetPercent -ne 75 -or
    [int]$pendingPlan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$pendingPlan.readiness.outcome -ne 'passed' -or
    [string]$pendingPlan.decision.nextAction -ne 'await-independent-recovery-final-expansion-approval'
) {
    throw 'The healthy recovery second expansion boundary did not produce the bounded 75-to-100-percent final expansion plan.'
}

Assert-PlanRejected `
    -FailureMessage 'The recovery final expansion contract accepted an invalid approval statement.' `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-final-expansion-plan.ps1') `
            -PlanPath $approvedPlanPath `
            -SecondExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy 'Recovery Second Expansion Owner' `
            -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

& (Join-Path $PSScriptRoot 'approve-production-incident-recovery-final-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Recovery Second Expansion Owner' `
    -ApprovalStatement ([string]$pendingPlan.approval.requiredStatement) `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted failed execution evidence.' `
    -Action {
        New-TestRecoveryFinalExpansionPlan `
            -SecondExpansionEvidencePath $failedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'failed-evidence') `
            -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-FAILED' `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted a target other than 100 percent.' `
    -Action {
        New-TestRecoveryFinalExpansionPlan `
            -SecondExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'oversized-target') `
            -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-LARGE' `
            -TargetPercent 99 `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted traffic outside the proven boundary.' `
    -Action {
        New-TestRecoveryFinalExpansionPlan `
            -SecondExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-observation') `
            -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-MISMATCH' `
            -ObservedTrafficPercent 74 `
            -ReferenceTime $contractClock | Out-Null
    }

$degradedPlanPath = New-TestRecoveryFinalExpansionPlan `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'degraded') `
    -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-DEGRADED' `
    -OperationalStatus degraded `
    -ReferenceTime $contractClock
$degradedPlan = Get-Content -Raw -LiteralPath $degradedPlanPath | ConvertFrom-Json
if (
    [string]$degradedPlan.state -ne 'blocked' -or
    [string]$degradedPlan.readiness.outcome -ne 'failed' -or
    [string]$degradedPlan.decision.nextAction -ne 'restore-previous-recovery-boundary-and-escalate'
) {
    throw 'Degraded recovery final expansion boundary observation did not remain blocked.'
}
Assert-PlanRejected `
    -FailureMessage 'The recovery final expansion gate allowed degraded observation evidence.' `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-gate.ps1') `
            -PlanPath $degradedPlanPath `
            -SecondExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

$unknownPlanPath = New-TestRecoveryFinalExpansionPlan `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-UNKNOWN' `
    -SecurityStatus unknown `
    -ReferenceTime $contractClock
$unknownPlan = Get-Content -Raw -LiteralPath $unknownPlanPath | ConvertFrom-Json
if (
    [string]$unknownPlan.state -ne 'blocked' -or
    [string]$unknownPlan.readiness.outcome -ne 'unknown' -or
    [string]$unknownPlan.decision.nextAction -ne 'hold-recovery-boundary-and-collect-evidence'
) {
    throw 'Unknown recovery final expansion boundary observation did not fail closed.'
}

$pendingChangePlanPath = New-TestRecoveryFinalExpansionPlan `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-PENDING' `
    -FinalExpansionChangeStatus pending `
    -ReferenceTime $contractClock
$pendingChangePlan = Get-Content -Raw -LiteralPath $pendingChangePlanPath | ConvertFrom-Json
if ([string]$pendingChangePlan.state -ne 'blocked' -or [string]$pendingChangePlan.readiness.outcome -ne 'unknown') {
    throw 'A pending external recovery final expansion change did not fail closed.'
}

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted an incomplete observation window.' `
    -Action {
        New-TestRecoveryFinalExpansionPlan `
            -SecondExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'short-observation') `
            -FinalExpansionChangeId 'CHG-TEST-RECOVERY-FINAL-EXPANSION-SHORT' `
            -ObservationStartedAt $contractClock.AddMinutes(-5) `
            -ObservationEndedAt $contractClock `
            -ReferenceTime $contractClock | Out-Null
    }

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 99
    [System.IO.File]::WriteAllText(
        $approvedPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -SecondExpansionEvidencePath $passedEvidencePath `
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
    throw 'The recovery final expansion gate allowed a tampered approved plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -SecondExpansionEvidencePath $passedEvidencePath `
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
    throw 'The recovery final expansion gate allowed changed second expansion execution evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -SecondExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery final expansion observation and planning contract passed.'
