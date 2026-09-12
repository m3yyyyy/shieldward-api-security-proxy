[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryProgressivePlan {
    param(
        [Parameter(Mandatory)][string]$ExpansionEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ProgressiveChangeId,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$TargetPercent = 50,
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
        [string]$ProgressiveChangeStatus = 'approved',
        [Nullable[DateTimeOffset]]$ObservationStartedAt = $null,
        [Nullable[DateTimeOffset]]$ObservationEndedAt = $null
    )

    $evidence = Get-Content -Raw -LiteralPath $ExpansionEvidencePath | ConvertFrom-Json
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

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-progressive-plan.ps1') `
        -ExpansionEvidencePath $ExpansionEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ProgressiveChangeId $ProgressiveChangeId `
        -ApprovalOwner 'Recovery Progressive Owner' `
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
        -ProgressiveChangeStatus $ProgressiveChangeStatus `
        -PreviousExecutionGateReference ('RECOVERY-EXPANSION-EXECUTION-GATE-' + [string]$evidence.expansionChangeId) `
        -TrafficObservationReference ('RECOVERY-PROGRESSIVE-TRAFFIC-' + [string]$evidence.incidentId) `
        -MonitoringEvidenceReference ('RECOVERY-PROGRESSIVE-MONITORING-' + [string]$evidence.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-PROGRESSIVE-ROLLBACK-' + [string]$evidence.incidentId) `
        -IncidentRecordReference ('INCIDENT-RECOVERY-PROGRESSIVE-' + [string]$evidence.incidentId) `
        -ProgressiveChangeReference ('CHANGE-' + $ProgressiveChangeId) `
        -ReviewedBy 'Recovery Progressive Reviewer' `
        -ObservationMinutes 15 `
        -MaxExpansionEvidenceAgeMinutes 60 `
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
$expansionEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-expansion-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-progressive-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-evidence-contract.ps1') 6>$null

$passedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'passed') -Filter 'expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $expansionEvidenceRoot 'failed-workload') -Filter 'expansion-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$passedEvidence.collectedAtUtc).ToUniversalTime().AddMinutes(20)

$approvedPlanPath = New-TestRecoveryProgressivePlan `
    -ExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-001' `
    -ReferenceTime $contractClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -ExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
if (
    [int]$pendingPlan.traffic.currentPercent -ne 25 -or
    [int]$pendingPlan.traffic.targetPercent -ne 50 -or
    [int]$pendingPlan.rollback.targetPercent -ne 25 -or
    [int]$pendingPlan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$pendingPlan.readiness.outcome -ne 'passed' -or
    [string]$pendingPlan.decision.nextAction -ne 'await-independent-recovery-progressive-approval'
) {
    throw 'The healthy recovery expansion boundary did not produce the bounded 25-to-50-percent progressive plan.'
}

Assert-PlanRejected `
    -FailureMessage 'The recovery progressive expansion contract accepted an invalid approval statement.' `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-progressive-plan.ps1') `
            -PlanPath $approvedPlanPath `
            -ExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy 'Recovery Progressive Owner' `
            -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

& (Join-Path $PSScriptRoot 'approve-production-incident-recovery-progressive-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -ExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Recovery Progressive Owner' `
    -ApprovalStatement ([string]$pendingPlan.approval.requiredStatement) `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -ExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Assert-PlanRejected `
    -FailureMessage 'Progressive recovery expansion accepted failed execution evidence.' `
    -Action {
        New-TestRecoveryProgressivePlan `
            -ExpansionEvidencePath $failedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'failed-evidence') `
            -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-FAILED' `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Progressive recovery expansion accepted a target above 50 percent.' `
    -Action {
        New-TestRecoveryProgressivePlan `
            -ExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'oversized-target') `
            -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-LARGE' `
            -TargetPercent 51 `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Progressive recovery expansion accepted traffic outside the proven boundary.' `
    -Action {
        New-TestRecoveryProgressivePlan `
            -ExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-observation') `
            -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-MISMATCH' `
            -ObservedTrafficPercent 24 `
            -ReferenceTime $contractClock | Out-Null
    }

$degradedPlanPath = New-TestRecoveryProgressivePlan `
    -ExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'degraded') `
    -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-DEGRADED' `
    -OperationalStatus degraded `
    -ReferenceTime $contractClock
$degradedPlan = Get-Content -Raw -LiteralPath $degradedPlanPath | ConvertFrom-Json
if (
    [string]$degradedPlan.state -ne 'blocked' -or
    [string]$degradedPlan.readiness.outcome -ne 'failed' -or
    [string]$degradedPlan.decision.nextAction -ne 'restore-previous-recovery-boundary-and-escalate'
) {
    throw 'Degraded recovery progressive expansion boundary observation did not remain blocked.'
}
Assert-PlanRejected `
    -FailureMessage 'The recovery progressive expansion gate allowed degraded observation evidence.' `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-gate.ps1') `
            -PlanPath $degradedPlanPath `
            -ExpansionEvidencePath $passedEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

$unknownPlanPath = New-TestRecoveryProgressivePlan `
    -ExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-UNKNOWN' `
    -SecurityStatus unknown `
    -ReferenceTime $contractClock
$unknownPlan = Get-Content -Raw -LiteralPath $unknownPlanPath | ConvertFrom-Json
if (
    [string]$unknownPlan.state -ne 'blocked' -or
    [string]$unknownPlan.readiness.outcome -ne 'unknown' -or
    [string]$unknownPlan.decision.nextAction -ne 'hold-recovery-boundary-and-collect-evidence'
) {
    throw 'Unknown recovery progressive expansion boundary observation did not fail closed.'
}

$pendingChangePlanPath = New-TestRecoveryProgressivePlan `
    -ExpansionEvidencePath $passedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-PENDING' `
    -ProgressiveChangeStatus pending `
    -ReferenceTime $contractClock
$pendingChangePlan = Get-Content -Raw -LiteralPath $pendingChangePlanPath | ConvertFrom-Json
if ([string]$pendingChangePlan.state -ne 'blocked' -or [string]$pendingChangePlan.readiness.outcome -ne 'unknown') {
    throw 'A pending external recovery progressive expansion change did not fail closed.'
}

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted an incomplete observation window.' `
    -Action {
        New-TestRecoveryProgressivePlan `
            -ExpansionEvidencePath $passedEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'short-observation') `
            -ProgressiveChangeId 'CHG-TEST-RECOVERY-PROGRESSIVE-SHORT' `
            -ObservationStartedAt $contractClock.AddMinutes(-5) `
            -ObservationEndedAt $contractClock `
            -ReferenceTime $contractClock | Out-Null
    }

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 49
    [System.IO.File]::WriteAllText(
        $approvedPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -ExpansionEvidencePath $passedEvidencePath `
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
    throw 'The recovery progressive expansion gate allowed a tampered approved plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -ExpansionEvidencePath $passedEvidencePath `
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
    throw 'The recovery progressive expansion gate allowed changed expansion execution evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -ExpansionEvidencePath $passedEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery progressive observation and expansion planning contract passed.'
