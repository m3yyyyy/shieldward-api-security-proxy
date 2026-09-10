[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestContainmentEvidence {
    param([Parameter(Mandatory)][string]$Directory)

    $evidence = Get-ChildItem -LiteralPath $Directory -Filter 'containment-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $evidence) {
        throw "Synthetic containment evidence is missing beneath $Directory."
    }
    return $evidence.FullName
}

function New-TestRecoveryPlan {
    param(
        [Parameter(Mandatory)][string]$ContainmentEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$RecoveryChangeId,
        [Parameter(Mandatory)][int]$TargetTrafficPercent,
        [string]$CurrentTrafficStatus = 'confirmed',
        [string]$RemediationStatus = 'completed',
        [string]$ReacceptanceStatus = 'passed',
        [string]$FunctionalStatus = 'passed',
        [string]$DependencyStatus = 'healthy',
        [string]$OperationalStatus = 'healthy',
        [string]$CapacityStatus = 'healthy',
        [string]$SecurityStatus = 'clear',
        [string]$DriftStatus = 'clear',
        [string]$CertificateStatus = 'healthy',
        [string]$IncidentRecordStatus = 'updated',
        [string]$RecoveryChangeStatus = 'approved'
    )

    $containment = Get-Content -Raw -LiteralPath $ContainmentEvidencePath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-plan.ps1') `
        -ContainmentEvidencePath $ContainmentEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -RecoveryChangeId $RecoveryChangeId `
        -RecoveryOwner ([string]$containment.response.authority) `
        -TargetTrafficPercent $TargetTrafficPercent `
        -CurrentTrafficStatus $CurrentTrafficStatus `
        -RemediationStatus $RemediationStatus `
        -ReacceptanceStatus $ReacceptanceStatus `
        -FunctionalStatus $FunctionalStatus `
        -DependencyStatus $DependencyStatus `
        -OperationalStatus $OperationalStatus `
        -CapacityStatus $CapacityStatus `
        -SecurityStatus $SecurityStatus `
        -DriftStatus $DriftStatus `
        -CertificateStatus $CertificateStatus `
        -IncidentRecordStatus $IncidentRecordStatus `
        -RecoveryChangeStatus $RecoveryChangeStatus `
        -TrafficStateReference ("TRAFFIC-RECOVERY-" + [string]$containment.incidentId) `
        -RemediationEvidenceReference ("REMEDIATION-" + [string]$containment.incidentId) `
        -ReacceptanceEvidenceReference ("REACCEPTANCE-" + [string]$containment.incidentId) `
        -RecoveryVerificationReference ("VERIFY-RECOVERY-" + [string]$containment.incidentId) `
        -IncidentRecordReference ("INCIDENT-RECOVERY-" + [string]$containment.incidentId) `
        -RecoveryChangeReference $RecoveryChangeId `
        -ReviewedBy 'Recovery Contract Reviewer' `
        -ApprovalWindowMinutes 60 `
        -MaxContainmentAgeMinutes 10080 `
        -OutputDirectory $OutputDirectory `
        -Force 3>$null 6>$null

    return (Join-Path $OutputDirectory 'recovery.json')
}

function Approve-TestRecoveryPlan {
    param([Parameter(Mandatory)][string]$PlanPath)

    $plan = Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-plan.ps1') `
        -PlanPath $PlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy ([string]$plan.approval.owner) `
        -ApprovalStatement ([string]$plan.approval.requiredStatement) 6>$null
}

function Assert-Rejected {
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
$containmentRoot = Join-Path $repoRoot '.shieldward/production-incident-containment-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-contract'

& (Join-Path $PSScriptRoot 'test-production-incident-containment-contract.ps1') 6>$null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$holdContainmentPath = Get-LatestContainmentEvidence -Directory (Join-Path $containmentRoot 'hold')
$rollbackContainmentPath = Get-LatestContainmentEvidence -Directory (Join-Path $containmentRoot 'rollback')
$disableContainmentPath = Get-LatestContainmentEvidence -Directory (Join-Path $containmentRoot 'disable')

$zeroRecoveryPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $disableContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'zero-to-canary') `
    -RecoveryChangeId 'RECOVERY-ZERO-001' `
    -TargetTrafficPercent 1 `
    -RemediationStatus completed `
    -ReacceptanceStatus not-required
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') `
    -PlanPath $zeroRecoveryPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending 6>$null
$zeroRecoveryPlan = Get-Content -Raw -LiteralPath $zeroRecoveryPlanPath | ConvertFrom-Json
if (
    [string]$zeroRecoveryPlan.recovery.mode -ne 'bounded-canary-restoration' -or
    [int]$zeroRecoveryPlan.traffic.currentPercent -ne 0 -or
    [int]$zeroRecoveryPlan.traffic.targetPercent -ne 1 -or
    [int]$zeroRecoveryPlan.rollback.targetPercent -ne 0
) {
    throw 'Zero-traffic recovery did not preserve the bounded canary and rollback contract.'
}
Approve-TestRecoveryPlan -PlanPath $zeroRecoveryPlanPath
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
    -PlanPath $zeroRecoveryPlanPath `
    -ExpectedProductionContext 'production-contract' 6>$null

$rollbackRecoveryPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $rollbackContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'seventy-five-to-full') `
    -RecoveryChangeId 'RECOVERY-SEVENTY-FIVE-001' `
    -TargetTrafficPercent 100 `
    -RemediationStatus completed `
    -ReacceptanceStatus not-required
Approve-TestRecoveryPlan -PlanPath $rollbackRecoveryPlanPath
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
    -PlanPath $rollbackRecoveryPlanPath `
    -ExpectedProductionContext 'production-contract' 6>$null
$rollbackRecoveryPlan = Get-Content -Raw -LiteralPath $rollbackRecoveryPlanPath | ConvertFrom-Json
if (
    [string]$rollbackRecoveryPlan.recovery.mode -ne 'restore-full-traffic' -or
    [int]$rollbackRecoveryPlan.traffic.currentPercent -ne 75 -or
    [int]$rollbackRecoveryPlan.traffic.targetPercent -ne 100 -or
    [int]$rollbackRecoveryPlan.rollback.targetPercent -ne 75
) {
    throw 'The 75 percent recovery did not preserve the exact full-traffic and rollback contract.'
}

$holdRecoveryPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $holdContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'hold-at-full') `
    -RecoveryChangeId 'RECOVERY-HOLD-001' `
    -TargetTrafficPercent 100 `
    -RemediationStatus not-required `
    -ReacceptanceStatus passed
Approve-TestRecoveryPlan -PlanPath $holdRecoveryPlanPath
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
    -PlanPath $holdRecoveryPlanPath `
    -ExpectedProductionContext 'production-contract' 6>$null
$holdRecoveryPlan = Get-Content -Raw -LiteralPath $holdRecoveryPlanPath | ConvertFrom-Json
if (
    [string]$holdRecoveryPlan.recovery.mode -ne 'resume-at-current-boundary' -or
    [bool]$holdRecoveryPlan.readiness.reacceptanceRequired -ne $true
) {
    throw 'The 100 percent hold recovery did not preserve mandatory re-acceptance.'
}

$invalidTargetRejected = $false
try {
    New-TestRecoveryPlan `
        -ContainmentEvidencePath $disableContainmentPath `
        -OutputDirectory (Join-Path $testRoot 'invalid-target') `
        -RecoveryChangeId 'RECOVERY-INVALID-TARGET-001' `
        -TargetTrafficPercent 25 | Out-Null
}
catch {
    $invalidTargetRejected = $true
}
if (-not $invalidTargetRejected) {
    throw 'Recovery from zero traffic allowed a target outside the 1-10 percent canary boundary.'
}

$failedRemediationPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $disableContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'failed-remediation') `
    -RecoveryChangeId 'RECOVERY-FAILED-REMEDIATION-001' `
    -TargetTrafficPercent 1 `
    -RemediationStatus failed `
    -ReacceptanceStatus not-required
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') `
    -PlanPath $failedRemediationPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Blocked 6>$null
Assert-Rejected `
    -Action { Approve-TestRecoveryPlan -PlanPath $failedRemediationPlanPath } `
    -FailureMessage 'A failed remediation plan was approved.'
Assert-Rejected `
    -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
            -PlanPath $failedRemediationPlanPath `
            -ExpectedProductionContext 'production-contract' 6>$null
    } `
    -FailureMessage 'The recovery gate allowed failed remediation.'

$missingReacceptancePlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $holdContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'missing-reacceptance') `
    -RecoveryChangeId 'RECOVERY-MISSING-REACCEPTANCE-001' `
    -TargetTrafficPercent 100 `
    -RemediationStatus not-required `
    -ReacceptanceStatus not-required
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') `
    -PlanPath $missingReacceptancePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Blocked 6>$null
Assert-Rejected `
    -Action { Approve-TestRecoveryPlan -PlanPath $missingReacceptancePlanPath } `
    -FailureMessage 'A recovery plan bypassed required re-acceptance.'

$unknownTrafficPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $disableContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-traffic') `
    -RecoveryChangeId 'RECOVERY-UNKNOWN-TRAFFIC-001' `
    -TargetTrafficPercent 1 `
    -CurrentTrafficStatus unknown `
    -RemediationStatus completed `
    -ReacceptanceStatus not-required
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') `
    -PlanPath $unknownTrafficPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Blocked 6>$null
Assert-Rejected `
    -Action { Approve-TestRecoveryPlan -PlanPath $unknownTrafficPlanPath } `
    -FailureMessage 'A recovery plan with unknown current traffic was approved.'

$pendingChangePlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $disableContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'pending-change') `
    -RecoveryChangeId 'RECOVERY-PENDING-CHANGE-001' `
    -TargetTrafficPercent 1 `
    -RemediationStatus completed `
    -ReacceptanceStatus not-required `
    -RecoveryChangeStatus pending
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') `
    -PlanPath $pendingChangePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Blocked 6>$null
Assert-Rejected `
    -Action { Approve-TestRecoveryPlan -PlanPath $pendingChangePlanPath } `
    -FailureMessage 'A recovery plan with a pending external change was approved.'

$approvalMismatchPlanPath = New-TestRecoveryPlan `
    -ContainmentEvidencePath $disableContainmentPath `
    -OutputDirectory (Join-Path $testRoot 'approval-mismatch') `
    -RecoveryChangeId 'RECOVERY-APPROVAL-MISMATCH-001' `
    -TargetTrafficPercent 1 `
    -RemediationStatus completed `
    -ReacceptanceStatus not-required
$approvalMismatchPlan = Get-Content -Raw -LiteralPath $approvalMismatchPlanPath | ConvertFrom-Json
Assert-Rejected `
    -Action {
        & (Join-Path $PSScriptRoot 'approve-production-incident-recovery-plan.ps1') `
            -PlanPath $approvalMismatchPlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy ([string]$approvalMismatchPlan.approval.owner) `
            -ApprovalStatement 'WRONG RECOVERY APPROVAL' 6>$null
    } `
    -FailureMessage 'The recovery plan accepted an inexact approval statement.'

$originalRecoveryPlan = [System.IO.File]::ReadAllText($zeroRecoveryPlanPath)
$recoveryPlanTamperingRejected = $false
try {
    $tamperedRecoveryPlan = $originalRecoveryPlan | ConvertFrom-Json -AsHashtable
    $tamperedRecoveryPlan['externalEvidence']['trafficStateReference'] = 'TAMPERED-RECOVERY-TRAFFIC'
    [System.IO.File]::WriteAllText(
        $zeroRecoveryPlanPath,
        (($tamperedRecoveryPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
            -PlanPath $zeroRecoveryPlanPath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $recoveryPlanTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($zeroRecoveryPlanPath, $originalRecoveryPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $recoveryPlanTamperingRejected) {
    throw 'The recovery gate allowed a tampered approved recovery plan.'
}

$containmentTimestampTamperingRejected = $false
try {
    $tamperedRecoveryPlan = $originalRecoveryPlan | ConvertFrom-Json -AsHashtable
    $recordedContainmentTime = [DateTimeOffset]$tamperedRecoveryPlan['containmentEvidence']['collectedAtUtc']
    $tamperedRecoveryPlan['containmentEvidence']['collectedAtUtc'] = $recordedContainmentTime.AddMinutes(-1).ToString('o')
    [System.IO.File]::WriteAllText(
        $zeroRecoveryPlanPath,
        (($tamperedRecoveryPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
            -PlanPath $zeroRecoveryPlanPath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $containmentTimestampTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($zeroRecoveryPlanPath, $originalRecoveryPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $containmentTimestampTamperingRejected) {
    throw 'The recovery gate allowed a changed recorded containment timestamp.'
}

$originalContainmentEvidence = [System.IO.File]::ReadAllText($disableContainmentPath)
$containmentTamperingRejected = $false
try {
    $tamperedContainment = $originalContainmentEvidence | ConvertFrom-Json -AsHashtable
    $tamperedContainment['externalEvidence']['incidentRecordReference'] = 'TAMPERED-CONTAINMENT-INCIDENT'
    [System.IO.File]::WriteAllText(
        $disableContainmentPath,
        (($tamperedContainment | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
            -PlanPath $zeroRecoveryPlanPath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $containmentTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($disableContainmentPath, $originalContainmentEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $containmentTamperingRejected) {
    throw 'The recovery gate allowed changed containment evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-gate.ps1') `
    -PlanPath $zeroRecoveryPlanPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Write-Host 'Production incident recovery planning contract passed.'
