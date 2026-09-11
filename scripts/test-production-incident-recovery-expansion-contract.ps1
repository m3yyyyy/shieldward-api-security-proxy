[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryExpansionPlan {
    param(
        [Parameter(Mandatory)][string]$RecoveryEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$ExpansionChangeId,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$TargetPercent = 25,
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
        [string]$ExpansionChangeStatus = 'approved',
        [Nullable[DateTimeOffset]]$ObservationStartedAt = $null,
        [Nullable[DateTimeOffset]]$ObservationEndedAt = $null
    )

    $evidence = Get-Content -Raw -LiteralPath $RecoveryEvidencePath | ConvertFrom-Json
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

    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-expansion-plan.ps1') `
        -RecoveryEvidencePath $RecoveryEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ExpansionChangeId $ExpansionChangeId `
        -ApprovalOwner 'Recovery Expansion Owner' `
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
        -ExpansionChangeStatus $ExpansionChangeStatus `
        -RecoveryEvidenceGateReference ('RECOVERY-EVIDENCE-GATE-' + [string]$evidence.incidentId) `
        -TrafficObservationReference ('RECOVERY-CANARY-TRAFFIC-' + [string]$evidence.incidentId) `
        -MonitoringEvidenceReference ('RECOVERY-CANARY-MONITORING-' + [string]$evidence.incidentId) `
        -RollbackEvidenceReference ('RECOVERY-CANARY-ROLLBACK-' + [string]$evidence.incidentId) `
        -IncidentRecordReference ('INCIDENT-RECOVERY-OBSERVATION-' + [string]$evidence.incidentId) `
        -ExpansionChangeReference ('CHANGE-' + $ExpansionChangeId) `
        -ReviewedBy 'Recovery Expansion Reviewer' `
        -ObservationMinutes 15 `
        -MaxRecoveryEvidenceAgeMinutes 60 `
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
$recoveryEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-expansion-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence-contract.ps1') 6>$null

$canaryEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $recoveryEvidenceRoot 'zero-to-canary') -Filter 'recovery-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$fullTrafficEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $recoveryEvidenceRoot 'hold-at-full') -Filter 'recovery-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$canaryEvidence = Get-Content -Raw -LiteralPath $canaryEvidencePath | ConvertFrom-Json
$contractClock = ([DateTimeOffset]$canaryEvidence.collectedAtUtc).ToUniversalTime().AddMinutes(20)

$approvedPlanPath = New-TestRecoveryExpansionPlan `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-001' `
    -ReferenceTime $contractClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
if (
    [int]$pendingPlan.traffic.currentPercent -ne 1 -or
    [int]$pendingPlan.traffic.targetPercent -ne 25 -or
    [int]$pendingPlan.rollback.targetPercent -ne 1 -or
    [int]$pendingPlan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$pendingPlan.readiness.outcome -ne 'passed' -or
    [string]$pendingPlan.decision.nextAction -ne 'await-independent-recovery-expansion-approval'
) {
    throw 'The healthy recovery canary did not produce the bounded 1-to-25-percent expansion plan.'
}

Assert-PlanRejected `
    -FailureMessage 'The recovery expansion contract accepted an invalid approval statement.' `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-expansion-plan.ps1') `
            -PlanPath $approvedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy 'Recovery Expansion Owner' `
            -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

& (Join-Path $PSScriptRoot 'approve-production-incident-recovery-expansion-plan.ps1') `
    -PlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Recovery Expansion Owner' `
    -ApprovalStatement ([string]$pendingPlan.approval.requiredStatement) `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted evidence that already represented full traffic.' `
    -Action {
        New-TestRecoveryExpansionPlan `
            -RecoveryEvidencePath $fullTrafficEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'full-traffic') `
            -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-FULL' `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted a target above 25 percent.' `
    -Action {
        New-TestRecoveryExpansionPlan `
            -RecoveryEvidencePath $canaryEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'oversized-target') `
            -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-LARGE' `
            -TargetPercent 30 `
            -ReferenceTime $contractClock | Out-Null
    }

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted traffic outside the proven recovery canary.' `
    -Action {
        New-TestRecoveryExpansionPlan `
            -RecoveryEvidencePath $canaryEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-observation') `
            -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-MISMATCH' `
            -ObservedTrafficPercent 2 `
            -ReferenceTime $contractClock | Out-Null
    }

$degradedPlanPath = New-TestRecoveryExpansionPlan `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'degraded') `
    -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-DEGRADED' `
    -OperationalStatus degraded `
    -ReferenceTime $contractClock
$degradedPlan = Get-Content -Raw -LiteralPath $degradedPlanPath | ConvertFrom-Json
if (
    [string]$degradedPlan.state -ne 'blocked' -or
    [string]$degradedPlan.readiness.outcome -ne 'failed' -or
    [string]$degradedPlan.decision.nextAction -ne 'restore-recovery-canary-and-escalate'
) {
    throw 'Degraded recovery canary observation did not remain blocked.'
}
Assert-PlanRejected `
    -FailureMessage 'The recovery expansion gate allowed degraded observation evidence.' `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-gate.ps1') `
            -PlanPath $degradedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }

$unknownPlanPath = New-TestRecoveryExpansionPlan `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-UNKNOWN' `
    -SecurityStatus unknown `
    -ReferenceTime $contractClock
$unknownPlan = Get-Content -Raw -LiteralPath $unknownPlanPath | ConvertFrom-Json
if (
    [string]$unknownPlan.state -ne 'blocked' -or
    [string]$unknownPlan.readiness.outcome -ne 'unknown' -or
    [string]$unknownPlan.decision.nextAction -ne 'hold-recovery-canary-and-collect-evidence'
) {
    throw 'Unknown recovery canary observation did not fail closed.'
}

$pendingChangePlanPath = New-TestRecoveryExpansionPlan `
    -RecoveryEvidencePath $canaryEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-PENDING' `
    -ExpansionChangeStatus pending `
    -ReferenceTime $contractClock
$pendingChangePlan = Get-Content -Raw -LiteralPath $pendingChangePlanPath | ConvertFrom-Json
if ([string]$pendingChangePlan.state -ne 'blocked' -or [string]$pendingChangePlan.readiness.outcome -ne 'unknown') {
    throw 'A pending external recovery expansion change did not fail closed.'
}

Assert-PlanRejected `
    -FailureMessage 'Recovery re-expansion accepted an incomplete observation window.' `
    -Action {
        New-TestRecoveryExpansionPlan `
            -RecoveryEvidencePath $canaryEvidencePath `
            -OutputDirectory (Join-Path $testRoot 'short-observation') `
            -ExpansionChangeId 'CHG-TEST-RECOVERY-EXPAND-SHORT' `
            -ObservationStartedAt $contractClock.AddMinutes(-5) `
            -ObservationEndedAt $contractClock `
            -ReferenceTime $contractClock | Out-Null
    }

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 24
    [System.IO.File]::WriteAllText(
        $approvedPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
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
    throw 'The recovery expansion gate allowed a tampered approved plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($canaryEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($canaryEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-gate.ps1') `
            -PlanPath $approvedPlanPath `
            -RecoveryEvidencePath $canaryEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $contractClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($canaryEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The recovery expansion gate allowed changed recovery execution evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-expansion-gate.ps1') `
    -PlanPath $approvedPlanPath `
    -RecoveryEvidencePath $canaryEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $contractClock.ToString('o') 6>$null

Write-Host 'Production recovery canary observation and expansion planning contract passed.'
