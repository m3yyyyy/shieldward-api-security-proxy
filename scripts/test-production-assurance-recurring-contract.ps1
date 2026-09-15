[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecurringEvidence {
    param(
        [Parameter(Mandatory)][string]$PreviousEvidencePath,
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

    $previous = Get-Content -Raw -LiteralPath $PreviousEvidencePath | ConvertFrom-Json
    $arguments = @{
        PreviousContinuityEvidencePath = $PreviousEvidencePath
        ExpectedProductionContext = 'production-contract'
        ReviewCompletedAtUtc = $ReferenceTime
        CompletionGraceMinutes = 15
        ObservedTrafficPercent = $ObservedTrafficPercent
        ReviewExecutionStatus = $ReviewExecutionStatus
        TrafficEnforcementStatus = $TrafficEnforcementStatus
        AssuranceScheduleStatus = $AssuranceScheduleStatus
        MonitoringCoverageStatus = $MonitoringCoverageStatus
        ErrorBudgetStatus = $ErrorBudgetStatus
        AlertStatus = $AlertStatus
        FunctionalStatus = $FunctionalStatus
        DependencyStatus = $DependencyStatus
        OperationalStatus = $OperationalStatus
        CapacityStatus = $CapacityStatus
        SecurityStatus = $SecurityStatus
        ImageDriftStatus = $ImageDriftStatus
        PolicyDriftStatus = $PolicyDriftStatus
        ConfigurationDriftStatus = $ConfigurationDriftStatus
        IdentityDriftStatus = $IdentityDriftStatus
        CertificateStatus = $CertificateStatus
        RoutingDriftStatus = $RoutingDriftStatus
        RollbackRetentionStatus = $RollbackRetentionStatus
        PreviousContinuityGateReference = 'RECURRING-PREVIOUS-GATE-' + [string]$previous.review.sequence
        ScheduledReviewReference = 'RECURRING-REVIEW-' + [string]([int]$previous.review.sequence + 1)
        TrafficStateReference = 'RECURRING-TRAFFIC-' + [string]$previous.incidentId
        MonitoringEvidenceReference = 'RECURRING-MONITORING-' + [string]$previous.incidentId
        DriftEvidenceReference = 'RECURRING-DRIFT-' + [string]$previous.incidentId
        RollbackRetentionReference = 'RECURRING-ROLLBACK-' + [string]$previous.incidentId
        ReviewedBy = 'Independent Recurring Assurance Reviewer'
        MaxPreviousEvidenceAgeHours = 168
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-recurring-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'review-*.json' |
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

function Assert-RecurringGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-recurring-gate.ps1') -EvidencePath $EvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$continuityRoot = Join-Path $repoRoot '.shieldward/production-assurance-continuity-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-recurring-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-continuity-contract.ps1') 6>$null

$continuityEvidencePath = (Get-ChildItem -LiteralPath $continuityRoot -Filter 'continuity-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$continuity = Get-Content -Raw -LiteralPath $continuityEvidencePath | ConvertFrom-Json
$secondReviewClock = ([DateTimeOffset]$continuity.schedule.nextReviewDueAtUtc).ToUniversalTime()

$passedEvidencePath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'passed-sequence-2') -ReferenceTime $secondReviewClock
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.review.sequence -ne 2 -or
    [int]$passedEvidence.review.previousSequence -ne 1 -or
    [bool]$passedEvidence.review.onTime -ne $true -or
    [bool]$passedEvidence.decision.continuityLinkValid -ne $true -or
    [bool]$passedEvidence.decision.continuityProven -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy recurring review sequence 2 did not prove continuity.'
}

$thirdReviewClock = ([DateTimeOffset]$passedEvidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$chainedEvidencePath = New-TestRecurringEvidence -PreviousEvidencePath $passedEvidencePath -OutputDirectory (Join-Path $testRoot 'passed-sequence-3') -ReferenceTime $thirdReviewClock
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-gate.ps1') -EvidencePath $chainedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $thirdReviewClock.ToString('o') 6>$null
$chainedEvidence = Get-Content -Raw -LiteralPath $chainedEvidencePath | ConvertFrom-Json
if (
    [int]$chainedEvidence.review.sequence -ne 3 -or
    [int]$chainedEvidence.previousContinuityEvidence.reviewSequence -ne 2 -or
    [string]$chainedEvidence.previousContinuityEvidence.evidenceType -ne 'recurring-production-assurance-continuity'
) {
    throw 'A later recurring review did not extend the exact previous review chain.'
}

Assert-Rejected -FailureMessage 'Recurring assurance accepted traffic outside the previous 100 percent boundary.' -Action {
    New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'mismatched-traffic') -ObservedTrafficPercent 99 -ReferenceTime $secondReviewClock | Out-Null
}

$lateReviewPath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'late-review') -ReferenceTime $secondReviewClock.AddMinutes(16)
$lateReview = Get-Content -Raw -LiteralPath $lateReviewPath | ConvertFrom-Json
if (
    [bool]$lateReview.review.onTime -ne $false -or
    [string]$lateReview.outcome -ne 'failed' -or
    [string]$lateReview.decision.nextAction -ne 'escalate-missed-assurance-review'
) {
    throw 'A late recurring review did not fail continuity and require escalation.'
}
Assert-Rejected -FailureMessage 'Failed recurring evidence was accepted as the next review boundary.' -Action {
    New-TestRecurringEvidence -PreviousEvidencePath $lateReviewPath -OutputDirectory (Join-Path $testRoot 'failed-previous-link') -ReferenceTime ([DateTimeOffset]$lateReview.schedule.nextReviewDueAtUtc) | Out-Null
}

$missedReviewPath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'missed-review') -ReviewExecutionStatus missed -ReferenceTime $secondReviewClock
Assert-RecurringGateRejected -EvidencePath $missedReviewPath -ReferenceTime $secondReviewClock -FailureMessage 'The recurring assurance gate accepted a missed scheduled review.'

$unknownReviewPath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'unknown-review') -ReviewExecutionStatus unknown -ReferenceTime $secondReviewClock
$unknownReview = Get-Content -Raw -LiteralPath $unknownReviewPath | ConvertFrom-Json
if ([string]$unknownReview.outcome -ne 'unknown' -or [string]$unknownReview.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown recurring review execution did not fail closed.'
}

$inactiveSchedulePath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'inactive-schedule') -AssuranceScheduleStatus inactive -ReferenceTime $secondReviewClock
$inactiveSchedule = Get-Content -Raw -LiteralPath $inactiveSchedulePath | ConvertFrom-Json
if ([string]$inactiveSchedule.decision.nextAction -ne 'escalate-missed-assurance-review') {
    throw 'An inactive recurring schedule did not require missed-review escalation.'
}

$driftEvidencePath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'drift') -PolicyDriftStatus detected -ReferenceTime $secondReviewClock
$driftEvidence = Get-Content -Raw -LiteralPath $driftEvidencePath | ConvertFrom-Json
if ([string]$driftEvidence.decision.nextAction -ne 'reaccept-before-continuing') {
    throw 'Recurring material drift did not require re-acceptance.'
}

$securityIncidentPath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'security-incident') -SecurityStatus incident -ReferenceTime $secondReviewClock
$securityIncident = Get-Content -Raw -LiteralPath $securityIncidentPath | ConvertFrom-Json
if ([string]$securityIncident.decision.nextAction -ne 'disable-and-investigate') {
    throw 'A recurring security incident did not require disablement and investigation.'
}

$missingRollbackPath = New-TestRecurringEvidence -PreviousEvidencePath $continuityEvidencePath -OutputDirectory (Join-Path $testRoot 'missing-rollback') -RollbackRetentionStatus missing -ReferenceTime $secondReviewClock
$missingRollback = Get-Content -Raw -LiteralPath $missingRollbackPath | ConvertFrom-Json
if (
    [bool]$missingRollback.decision.monitoringContinues -ne $true -or
    [bool]$missingRollback.decision.continuityProven -ne $false -or
    [string]$missingRollback.outcome -ne 'failed'
) {
    throw 'Missing rollback did not preserve monitoring facts while blocking recurring continuity.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['decision']['continuityLinkValid'] = $false
    [System.IO.File]::WriteAllText($passedEvidencePath, (($tamperedEvidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Recurring assurance evidence tampering was not rejected.'
}

$originalPreviousEvidence = [System.IO.File]::ReadAllText($continuityEvidencePath)
$previousTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($continuityEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
    }
    catch {
        $previousTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($continuityEvidencePath, $originalPreviousEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $previousTamperingRejected) {
    throw 'Changed previous continuity evidence was not rejected.'
}

Assert-RecurringGateRejected -EvidencePath $passedEvidencePath -ReferenceTime $secondReviewClock.AddMinutes(61) -FailureMessage 'The recurring assurance gate accepted stale or overdue evidence.'
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null

Write-Host 'Recurring production assurance continuity evidence contract passed.'
