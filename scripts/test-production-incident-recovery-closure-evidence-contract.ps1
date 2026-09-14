[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecoveryClosureEvidence {
    param(
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = 100,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$ClosureExecutionStatus = 'completed',
        [string]$IncidentClosureStatus = 'closed',
        [string]$ClosureChangeRecordStatus = 'completed',
        [string]$PostClosureMonitoringStatus = 'healthy',
        [string]$RollbackRetentionStatus = 'retained',
        [string]$AuditEvidenceStatus = 'complete'
    )

    $plan = Get-Content -Raw -LiteralPath $ClosurePlanPath | ConvertFrom-Json
    $closedAt = $ReferenceTime.ToUniversalTime().AddMinutes(-5)
    & (Join-Path $PSScriptRoot 'new-production-incident-recovery-closure-evidence.ps1') `
        -ClosurePlanPath $ClosurePlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ClosedAtUtc $closedAt `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -ClosureExecutionStatus $ClosureExecutionStatus `
        -IncidentClosureStatus $IncidentClosureStatus `
        -ClosureChangeRecordStatus $ClosureChangeRecordStatus `
        -PostClosureMonitoringStatus $PostClosureMonitoringStatus `
        -RollbackRetentionStatus $RollbackRetentionStatus `
        -AuditEvidenceStatus $AuditEvidenceStatus `
        -ClosureGateReference ('RECOVERY-CLOSURE-GATE-' + [string]$plan.closureChangeId) `
        -IncidentClosureReference ('INCIDENT-CLOSURE-' + [string]$plan.incidentId) `
        -ClosureChangeRecordReference ('CHANGE-CLOSURE-' + [string]$plan.closureChangeId) `
        -PostClosureMonitoringReference ('POST-CLOSURE-MONITORING-' + [string]$plan.incidentId) `
        -TrafficStateReference ('POST-CLOSURE-TRAFFIC-' + [string]$plan.incidentId) `
        -RollbackRetentionReference ('POST-CLOSURE-ROLLBACK-' + [string]$plan.incidentId) `
        -AuditEvidenceReference ('POST-CLOSURE-AUDIT-' + [string]$plan.incidentId) `
        -CollectedBy 'Independent Closure Evidence Collector' `
        -MaxClosureAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'closure-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
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

function Assert-ClosureEvidenceGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ClosurePlanPath $ClosurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$closurePlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-evidence-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-contract.ps1') 6>$null

$approvedPlanPath = Join-Path $closurePlanRoot 'approved/closure.json'
$approvedPlan = Get-Content -Raw -LiteralPath $approvedPlanPath | ConvertFrom-Json
$evidenceClock = ([DateTimeOffset]$approvedPlan.approval.approvedAtUtc).ToUniversalTime().AddMinutes(10)

$passedEvidencePath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $evidenceClock

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $evidenceClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $evidenceClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [string]$passedEvidence.closure.incidentStatus -ne 'closed' -or
    [bool]$passedEvidence.closure.recorded -ne $true -or
    [int]$passedEvidence.traffic.observedPercent -ne 100 -or
    [int]$passedEvidence.traffic.mutationPercentagePoints -ne 0 -or
    [int]$passedEvidence.rollback.targetPercent -ne 75 -or
    [string]$passedEvidence.verification.rollbackRetention -ne 'retained' -or
    [string]$passedEvidence.decision.nextAction -ne 'begin-post-incident-assurance-and-retrospective'
) {
    throw 'Healthy authoritative closure evidence did not produce the required passed outcome.'
}

$pendingPlanPath = Join-Path $testRoot 'pending-plan/closure.json'
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
Assert-Rejected `
    -FailureMessage 'Recovery closure evidence accepted a pending closure plan.' `
    -Action {
        New-TestRecoveryClosureEvidence `
            -ClosurePlanPath $pendingPlanPath `
            -OutputDirectory (Join-Path $testRoot 'pending-plan-evidence') `
            -ReferenceTime $evidenceClock | Out-Null
    }

Assert-Rejected `
    -FailureMessage 'Recovery closure evidence accepted traffic outside the proven 100 percent boundary.' `
    -Action {
        New-TestRecoveryClosureEvidence `
            -ClosurePlanPath $approvedPlanPath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-traffic') `
            -ObservedTrafficPercent 99 `
            -ReferenceTime $evidenceClock | Out-Null
    }

$openIncidentPath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'open-incident') `
    -IncidentClosureStatus open `
    -ReferenceTime $evidenceClock
$openIncidentEvidence = Get-Content -Raw -LiteralPath $openIncidentPath | ConvertFrom-Json
if ([string]$openIncidentEvidence.outcome -ne 'failed' -or [bool]$openIncidentEvidence.closure.recorded -ne $false) {
    throw 'An externally open incident did not produce a failed closure outcome.'
}
Assert-ClosureEvidenceGateRejected `
    -EvidencePath $openIncidentPath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock `
    -FailureMessage 'The recovery closure evidence gate accepted an open incident.'

$unknownClosurePath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-closure') `
    -ClosureExecutionStatus unknown `
    -IncidentClosureStatus unknown `
    -ReferenceTime $evidenceClock
$unknownClosureEvidence = Get-Content -Raw -LiteralPath $unknownClosurePath | ConvertFrom-Json
if (
    [string]$unknownClosureEvidence.outcome -ne 'unknown' -or
    [string]$unknownClosureEvidence.decision.nextAction -ne 'treat-incident-as-open-and-collect-closure-evidence'
) {
    throw 'Unknown external closure state did not fail closed.'
}

$failedChangePath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'failed-change') `
    -ClosureChangeRecordStatus failed `
    -ReferenceTime $evidenceClock
Assert-ClosureEvidenceGateRejected `
    -EvidencePath $failedChangePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock `
    -FailureMessage 'The recovery closure evidence gate accepted a failed closure change record.'

$degradedMonitoringPath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'degraded-monitoring') `
    -PostClosureMonitoringStatus degraded `
    -ReferenceTime $evidenceClock
Assert-ClosureEvidenceGateRejected `
    -EvidencePath $degradedMonitoringPath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock `
    -FailureMessage 'The recovery closure evidence gate accepted degraded post-closure monitoring.'

$missingRollbackPath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'missing-rollback') `
    -RollbackRetentionStatus missing `
    -ReferenceTime $evidenceClock
$missingRollbackEvidence = Get-Content -Raw -LiteralPath $missingRollbackPath | ConvertFrom-Json
if (
    [bool]$missingRollbackEvidence.closure.recorded -ne $true -or
    [string]$missingRollbackEvidence.outcome -ne 'failed' -or
    [string]$missingRollbackEvidence.decision.nextAction -ne 'reopen-or-escalate-incident-and-preserve-rollback'
) {
    throw 'Missing rollback retention did not preserve the factual closure record while failing the evidence gate.'
}
Assert-ClosureEvidenceGateRejected `
    -EvidencePath $missingRollbackPath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock `
    -FailureMessage 'The recovery closure evidence gate accepted missing rollback retention.'

$incompleteAuditPath = New-TestRecoveryClosureEvidence `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'incomplete-audit') `
    -AuditEvidenceStatus incomplete `
    -ReferenceTime $evidenceClock
Assert-ClosureEvidenceGateRejected `
    -EvidencePath $incompleteAuditPath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock `
    -FailureMessage 'The recovery closure evidence gate accepted incomplete audit evidence.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['closure']['recorded'] = $false
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ClosurePlanPath $approvedPlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $evidenceClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Recovery closure evidence tampering was not rejected.'
}

$originalPlan = [System.IO.File]::ReadAllText($approvedPlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($approvedPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ClosurePlanPath $approvedPlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $evidenceClock.ToString('o') 6>$null
    }
    catch {
        $approvedPlanTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($approvedPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $approvedPlanTamperingRejected) {
    throw 'Changed approved closure plan was not rejected by closure evidence validation.'
}

Assert-ClosureEvidenceGateRejected `
    -EvidencePath $passedEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $evidenceClock.AddMinutes(61) `
    -FailureMessage 'The recovery closure evidence gate accepted stale evidence.'

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $evidenceClock.ToString('o') 6>$null

Write-Host 'Production recovery incident closure execution evidence contract passed.'
