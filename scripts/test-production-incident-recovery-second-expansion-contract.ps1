[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoverySecondExpansionPlan {
    param(
        [Parameter(Mandatory)][string]$ProgressiveEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$SecondExpansionChangeId,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$TargetPercent = 75,
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
        [string]$SecondExpansionChangeStatus = 'approved',
        [Nullable[DateTimeOffset]]$ObservationStartedAt = $null,
        [Nullable[DateTimeOffset]]$ObservationEndedAt = $null
    )

    $evidence = Get-Content -Raw -LiteralPath $ProgressiveEvidencePath | ConvertFrom-Json
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

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-second-expansion-plan.ps1') `
        -ProgressiveEvidencePath $ProgressiveEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -SecondExpansionChangeId $SecondExpansionChangeId `
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
        -SecondExpansionChangeStatus $SecondExpansionChangeStatus `
        -PreviousExecutionGateReference ('RECOVERY-PROGRESSIVE-EXECUTION-GATE-' + [string]$evidence.progressiveChangeId) `
        -TrafficObservationReference ('RECOVERY-SECOND-EXPANSION-TRAFFIC-' + [string]$evidence.incidentId) `
        -MonitoringEvidenceReference ('RECOVERY-SECOND-EXPANSION-MONITORING-' + [string]$evidence.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-SECOND-EXPANSION-ROLLBACK-' + [string]$evidence.incidentId) `
        -IncidentRecordReference ('INCIDENT-RECOVERY-SECOND-EXPANSION-' + [string]$evidence.incidentId) `
        -SecondExpansionChangeReference ('CHANGE-' + $SecondExpansionChangeId) `
        -ReviewedBy 'Recovery Second Expansion Reviewer' `
        -ObservationMinutes 15 `
        -MaxProgressiveEvidenceAgeMinutes 60 `
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
$expansionEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-progressive-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-second-expansion-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-evidence-contract.ps1') 6>$null

$passedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'passed') -Filter 'progressive-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'failed-workload') -Filter 'progressive-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$passedEvidence.collectedAtUtc).ToUniversalTime().AddMinutes(20)

$approvedPlanPath = New-TestRecoverySecondExpansionPlan `
    -ProgressiveEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-001' `
    -ReferenceTime $contractClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -ProgressiveEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
if (
    [int]$pendingPlan.traffic.currentPercent -ne 50 -or
    [int]$pendingPlan.traffic.targetPercent -ne 75 -or
    [int]$pendingPlan.rollback.targetPercent -ne 50 -or
    [int]$pendingPlan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$pendingPlan.readiness.outcome -ne 'passed' -or
    [string]$pendingPlan.decision.nextAction -ne 'await-independent-recovery-second-expansion-approval'
) {
    throw 'The healthy recovery progressive boundary did not produce the bounded 50-to-75-percent second expansion plan.'
}

Assert-PlanRejected `
    -FailureMessage 'The recovery second expansion contract accepted an invalid approval statement.' `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-second-expansion-plan.ps1') `
            -PlanPath $approvedPlanPath `
            -ProgressiveEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy 'Recovery Second Expansion Owner' `
            -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

& (Join-Path $PSScriptRoot 'approve-production-incident-recovery-second-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -ProgressiveEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Recovery Second Expansion Owner' `
    -ApprovalStatement ([string]$pendingPlan.approval.requiredStatement) `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -ProgressiveEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted failed execution evidence.' `
    -Action {
        New-TestRecoverySecondExpansionPlan `
            -ProgressiveEvidencePath $failedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'failed-evidence') `
            -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-FAILED' `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted a target above 75 percent.' `
    -Action {
        New-TestRecoverySecondExpansionPlan `
            -ProgressiveEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'oversized-target') `
            -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-LARGE' `
            -TargetPercent 76 `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Second recovery expansion accepted traffic outside the proven boundary.' `
    -Action {
        New-TestRecoverySecondExpansionPlan `
            -ProgressiveEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-observation') `
            -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-MISMATCH' `
            -ObservedTrafficPercent 49 `
            -ReferenceTime $contractClock | Out-Null
    }

$degradedPlanPath = New-TestRecoverySecondExpansionPlan `
    -ProgressiveEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'degraded') `
    -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-DEGRADED' `
    -OperationalStatus degraded `
    -ReferenceTime $contractClock
$degradedPlan = Get-Content -Raw -LiteralPath $degradedPlanPath | ConvertFrom-Json
if (
    [string]$degradedPlan.state -ne 'blocked' -or
    [string]$degradedPlan.readiness.outcome -ne 'failed' -or
    [string]$degradedPlan.decision.nextAction -ne 'restore-previous-recovery-boundary-and-escalate'
) {
    throw 'Degraded recovery second expansion boundary observation did not remain blocked.'
}
Assert-PlanRejected `
    -FailureMessage 'The recovery second expansion gate allowed degraded observation evidence.' `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-gate.ps1') `
            -PlanPath $degradedPlanPath `
            -ProgressiveEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

$unknownPlanPath = New-TestRecoverySecondExpansionPlan `
    -ProgressiveEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-UNKNOWN' `
    -SecurityStatus unknown `
    -ReferenceTime $contractClock
$unknownPlan = Get-Content -Raw -LiteralPath $unknownPlanPath | ConvertFrom-Json
if (
    [string]$unknownPlan.state -ne 'blocked' -or
    [string]$unknownPlan.readiness.outcome -ne 'unknown' -or
    [string]$unknownPlan.decision.nextAction -ne 'hold-recovery-boundary-and-collect-evidence'
) {
    throw 'Unknown recovery second expansion boundary observation did not fail closed.'
}

$pendingChangePlanPath = New-TestRecoverySecondExpansionPlan `
    -ProgressiveEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-PENDING' `
    -SecondExpansionChangeStatus pending `
    -ReferenceTime $contractClock
$pendingChangePlan = Get-Content -Raw -LiteralPath $pendingChangePlanPath | ConvertFrom-Json
if ([string]$pendingChangePlan.state -ne 'blocked' -or [string]$pendingChangePlan.readiness.outcome -ne 'unknown') {
    throw 'A pending external recovery second expansion change did not fail closed.'
}

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted an incomplete observation window.' `
    -Action {
        New-TestRecoverySecondExpansionPlan `
            -ProgressiveEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'short-observation') `
            -SecondExpansionChangeId 'CHG-TEST-RECOVERY-SECOND-EXPANSION-SHORT' `
            -ObservationStartedAt $contractClock.AddMinutes(-5) `
            -ObservationEndedAt $contractClock `
            -ReferenceTime $contractClock | Out-Null
    }

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 74
    [System.IO.File]::WriteAllText(
        $approvedPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -ProgressiveEvidencePath $passedEvidencePath `
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
    throw 'The recovery second expansion gate allowed a tampered approved plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -ProgressiveEvidencePath $passedEvidencePath `
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
    throw 'The recovery second expansion gate allowed changed progressive execution evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -ProgressiveEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery second expansion observation and planning contract passed.'
