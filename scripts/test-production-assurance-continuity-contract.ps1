[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestAssuranceContinuityEvidence {
    param(
        [Parameter(Mandatory)][string]$ResumptionEvidencePath,
        [Parameter(Mandatory)][string]$PostIncidentEvidencePath,
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = 100,
        [string]$ReviewExecutionStatus = 'completed',
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$AssuranceScheduleStatus = 'active',
        [string]$MonitoringCoverageStatus = 'complete',
        [string]$ErrorBudgetStatus = 'within-budget',
        [string]$AlertStatus = 'clear',
        [string]$FunctionalStatus = 'passed',
        [string]$DependencyStatus = 'healthy',
        [string]$OperationalStatus = 'healthy',
        [string]$CapacityStatus = 'healthy',
        [string]$SecurityStatus = 'clear',
        [string]$ImageDriftStatus = 'clear',
        [string]$PolicyDriftStatus = 'clear',
        [string]$ConfigurationDriftStatus = 'clear',
        [string]$IdentityDriftStatus = 'clear',
        [string]$CertificateStatus = 'healthy',
        [string]$RoutingDriftStatus = 'clear',
        [string]$RollbackRetentionStatus = 'retained'
    )

    $resumption = Get-Content -Raw -LiteralPath $ResumptionEvidencePath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-assurance-continuity-evidence.ps1') `
        -ResumptionEvidencePath $ResumptionEvidencePath `
        -PostIncidentEvidencePath $PostIncidentEvidencePath `
        -ClosureEvidencePath $ClosureEvidencePath `
        -ClosurePlanPath $ClosurePlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ReviewCompletedAtUtc $ReferenceTime `
        -ReviewSequence 1 `
        -CompletionGraceMinutes 15 `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -ReviewExecutionStatus $ReviewExecutionStatus `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -AssuranceScheduleStatus $AssuranceScheduleStatus `
        -MonitoringCoverageStatus $MonitoringCoverageStatus `
        -ErrorBudgetStatus $ErrorBudgetStatus `
        -AlertStatus $AlertStatus `
        -FunctionalStatus $FunctionalStatus `
        -DependencyStatus $DependencyStatus `
        -OperationalStatus $OperationalStatus `
        -CapacityStatus $CapacityStatus `
        -SecurityStatus $SecurityStatus `
        -ImageDriftStatus $ImageDriftStatus `
        -PolicyDriftStatus $PolicyDriftStatus `
        -ConfigurationDriftStatus $ConfigurationDriftStatus `
        -IdentityDriftStatus $IdentityDriftStatus `
        -CertificateStatus $CertificateStatus `
        -RoutingDriftStatus $RoutingDriftStatus `
        -RollbackRetentionStatus $RollbackRetentionStatus `
        -ResumptionGateReference ('CONTINUITY-RESUMPTION-GATE-' + [string]$resumption.incidentId) `
        -ScheduledReviewReference ('CONTINUITY-REVIEW-' + [string]$resumption.incidentId) `
        -TrafficStateReference ('CONTINUITY-TRAFFIC-' + [string]$resumption.incidentId) `
        -MonitoringEvidenceReference ('CONTINUITY-MONITORING-' + [string]$resumption.incidentId) `
        -DriftEvidenceReference ('CONTINUITY-DRIFT-' + [string]$resumption.incidentId) `
        -RollbackRetentionReference ('CONTINUITY-ROLLBACK-' + [string]$resumption.incidentId) `
        -ReviewedBy 'Independent Assurance Continuity Reviewer' `
        -MaxResumptionEvidenceAgeHours 168 `
        -MaxReviewAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'continuity-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-Rejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$FailureMessage)

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

function Assert-ContinuityGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ResumptionEvidencePath,
        [Parameter(Mandatory)][string]$PostIncidentEvidencePath,
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-continuity-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ResumptionEvidencePath $ResumptionEvidencePath `
            -PostIncidentEvidencePath $PostIncidentEvidencePath `
            -ClosureEvidencePath $ClosureEvidencePath `
            -ClosurePlanPath $ClosurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$closurePlanPath = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-contract/approved/closure.json'
$closureEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-evidence-contract/passed'
$postIncidentRoot = Join-Path $repoRoot '.shieldward/production-post-incident-assurance-contract/passed'
$resumptionRoot = Join-Path $repoRoot '.shieldward/production-assurance-resumption-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-continuity-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-contract.ps1') 6>$null

$closureEvidencePath = (Get-ChildItem -LiteralPath $closureEvidenceRoot -Filter 'closure-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$postIncidentEvidencePath = (Get-ChildItem -LiteralPath $postIncidentRoot -Filter 'assurance-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$resumptionEvidencePath = (Get-ChildItem -LiteralPath $resumptionRoot -Filter 'resumption-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$resumption = Get-Content -Raw -LiteralPath $resumptionEvidencePath | ConvertFrom-Json
$reviewClock = ([DateTimeOffset]$resumption.schedule.nextReviewDueAtUtc).ToUniversalTime()

$passedEvidencePath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $reviewClock

& (Join-Path $PSScriptRoot 'test-production-assurance-continuity-evidence.ps1') `
    -EvidencePath $passedEvidencePath `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-assurance-continuity-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.review.sequence -ne 1 -or
    [string]$passedEvidence.review.executionStatus -ne 'completed' -or
    [bool]$passedEvidence.review.onTime -ne $true -or
    [bool]$passedEvidence.decision.monitoringContinues -ne $true -or
    [bool]$passedEvidence.decision.continuityProven -ne $true -or
    [int]$passedEvidence.traffic.observedPercent -ne 100 -or
    [string]$passedEvidence.rollback.retentionStatus -ne 'retained' -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy scheduled assurance review did not prove continuity.'
}

Assert-Rejected `
    -FailureMessage 'Assurance continuity accepted traffic outside the resumption 100 percent boundary.' `
    -Action {
        New-TestAssuranceContinuityEvidence `
            -ResumptionEvidencePath $resumptionEvidencePath `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-traffic') `
            -ObservedTrafficPercent 99 `
            -ReferenceTime $reviewClock | Out-Null
    }

$lateReviewPath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'late-review') `
    -ReferenceTime $reviewClock.AddMinutes(16)
$lateReview = Get-Content -Raw -LiteralPath $lateReviewPath | ConvertFrom-Json
if (
    [bool]$lateReview.review.onTime -ne $false -or
    [string]$lateReview.outcome -ne 'failed' -or
    [string]$lateReview.decision.nextAction -ne 'escalate-missed-assurance-review'
) {
    throw 'A late scheduled review did not fail continuity and require escalation.'
}

$missedReviewPath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'missed-review') `
    -ReviewExecutionStatus missed `
    -ReferenceTime $reviewClock
Assert-ContinuityGateRejected `
    -EvidencePath $missedReviewPath `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ReferenceTime $reviewClock `
    -FailureMessage 'The assurance continuity gate accepted a missed scheduled review.'

$unknownReviewPath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-review') `
    -ReviewExecutionStatus unknown `
    -ReferenceTime $reviewClock
$unknownReview = Get-Content -Raw -LiteralPath $unknownReviewPath | ConvertFrom-Json
if (
    [string]$unknownReview.outcome -ne 'unknown' -or
    [string]$unknownReview.decision.nextAction -ne 'investigate-and-refresh-evidence'
) {
    throw 'Unknown scheduled review execution did not fail closed.'
}

$inactiveSchedulePath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'inactive-schedule') `
    -AssuranceScheduleStatus inactive `
    -ReferenceTime $reviewClock
$inactiveSchedule = Get-Content -Raw -LiteralPath $inactiveSchedulePath | ConvertFrom-Json
if ([string]$inactiveSchedule.decision.nextAction -ne 'escalate-missed-assurance-review') {
    throw 'An inactive schedule did not require missed-review escalation.'
}

$driftEvidencePath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'drift') `
    -PolicyDriftStatus detected `
    -ReferenceTime $reviewClock
$driftEvidence = Get-Content -Raw -LiteralPath $driftEvidencePath | ConvertFrom-Json
if ([string]$driftEvidence.decision.nextAction -ne 'reaccept-before-continuing') {
    throw 'Material drift did not require re-acceptance.'
}

$securityIncidentPath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'security-incident') `
    -SecurityStatus incident `
    -ReferenceTime $reviewClock
$securityIncident = Get-Content -Raw -LiteralPath $securityIncidentPath | ConvertFrom-Json
if ([string]$securityIncident.decision.nextAction -ne 'disable-and-investigate') {
    throw 'A security incident did not require disablement and investigation.'
}

$missingRollbackPath = New-TestAssuranceContinuityEvidence `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'missing-rollback') `
    -RollbackRetentionStatus missing `
    -ReferenceTime $reviewClock
$missingRollback = Get-Content -Raw -LiteralPath $missingRollbackPath | ConvertFrom-Json
if (
    [bool]$missingRollback.decision.monitoringContinues -ne $true -or
    [bool]$missingRollback.decision.continuityProven -ne $false -or
    [string]$missingRollback.outcome -ne 'failed'
) {
    throw 'Missing rollback did not preserve monitoring facts while blocking continuity.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['review']['onTime'] = $false
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-continuity-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ResumptionEvidencePath $resumptionEvidencePath `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Assurance continuity evidence tampering was not rejected.'
}

$originalResumptionEvidence = [System.IO.File]::ReadAllText($resumptionEvidencePath)
$resumptionTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($resumptionEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-continuity-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ResumptionEvidencePath $resumptionEvidencePath `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null
    }
    catch {
        $resumptionTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($resumptionEvidencePath, $originalResumptionEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $resumptionTamperingRejected) {
    throw 'Changed resumption evidence was not rejected by continuity validation.'
}

Assert-ContinuityGateRejected `
    -EvidencePath $passedEvidencePath `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ReferenceTime $reviewClock.AddMinutes(61) `
    -FailureMessage 'The assurance continuity gate accepted stale evidence.'

& (Join-Path $PSScriptRoot 'test-production-assurance-continuity-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ResumptionEvidencePath $resumptionEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null

Write-Host 'Scheduled production assurance continuity evidence contract passed.'
