[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestRecurringCustodyReviewEvidence {
    param(
        [Parameter(Mandatory)][string]$PreviousEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [string]$ArchiveAvailabilityStatus = 'available',
        [string]$EvidenceInventoryStatus = 'complete',
        [string]$ObjectLockStatus = 'enforced',
        [string]$RetentionPolicyStatus = 'active',
        [string]$EncryptionStatus = 'verified',
        [string]$AccessControlStatus = 'least-privilege',
        [string]$RestoreVerificationStatus = 'passed'
    )

    $previous = Get-Content -Raw -LiteralPath $PreviousEvidencePath | ConvertFrom-Json
    $previousSequence = if ([string]$previous.evidenceType -eq 'scheduled-production-assurance-custody-review') {
        1
    }
    else {
        [int]$previous.review.sequence
    }
    $arguments = @{
        PreviousCustodyReviewEvidencePath = $PreviousEvidencePath
        ExpectedProductionContext = 'production-contract'
        ReviewCompletedAtUtc = $ReferenceTime
        CompletionGraceHours = 24
        ArchiveAvailabilityStatus = $ArchiveAvailabilityStatus
        EvidenceInventoryStatus = $EvidenceInventoryStatus
        ObjectLockStatus = $ObjectLockStatus
        RetentionPolicyStatus = $RetentionPolicyStatus
        EncryptionStatus = $EncryptionStatus
        AccessControlStatus = $AccessControlStatus
        RestoreVerificationStatus = $RestoreVerificationStatus
        PreviousCustodyReviewGateReference = 'RECURRING-CUSTODY-PREVIOUS-GATE-' + [string]$previousSequence
        ScheduledReviewReference = 'RECURRING-CUSTODY-SCHEDULE-' + [string]($previousSequence + 1)
        ArchiveInventoryReference = 'RECURRING-CUSTODY-INVENTORY-' + [string]$previous.incidentId
        ObjectLockReference = 'RECURRING-CUSTODY-OBJECT-LOCK-' + [string]$previous.incidentId
        RetentionPolicyReference = 'RECURRING-CUSTODY-RETENTION-' + [string]$previous.incidentId
        EncryptionReference = 'RECURRING-CUSTODY-ENCRYPTION-' + [string]$previous.incidentId
        AccessReviewReference = 'RECURRING-CUSTODY-ACCESS-' + [string]$previous.incidentId
        RestoreTestReference = 'RECURRING-CUSTODY-RESTORE-' + [string]$previous.incidentId
        ReviewedBy = 'Independent Recurring Custody Reviewer'
        MaxPreviousEvidenceAgeHours = 2208
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-custody-recurring-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'custody-review-*.json' |
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

function Assert-RecurringCustodyGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-gate.ps1') -EvidencePath $EvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scheduledRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-review-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-recurring-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-contract.ps1') 6>$null

$scheduledEvidencePath = (Get-ChildItem -LiteralPath $scheduledRoot -Filter 'custody-review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$scheduledEvidence = Get-Content -Raw -LiteralPath $scheduledEvidencePath | ConvertFrom-Json
$secondReviewClock = ([DateTimeOffset]$scheduledEvidence.schedule.nextReviewDueAtUtc).ToUniversalTime()

$sequence2Path = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'passed-sequence-2') -ReferenceTime $secondReviewClock
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-evidence.ps1') -EvidencePath $sequence2Path -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-gate.ps1') -EvidencePath $sequence2Path -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null

$sequence2 = Get-Content -Raw -LiteralPath $sequence2Path | ConvertFrom-Json
if (
    [string]$sequence2.outcome -ne 'passed' -or
    [int]$sequence2.review.sequence -ne 2 -or
    [int]$sequence2.review.previousSequence -ne 1 -or
    [bool]$sequence2.review.onTime -ne $true -or
    [bool]$sequence2.decision.custodyLinkValid -ne $true -or
    [bool]$sequence2.decision.custodyContinuityProven -ne $true -or
    [string]$sequence2.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy recurring custody review sequence 2 did not prove continuity.'
}

$thirdReviewClock = ([DateTimeOffset]$sequence2.schedule.nextReviewDueAtUtc).ToUniversalTime()
$sequence3Path = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $sequence2Path -OutputDirectory (Join-Path $testRoot 'passed-sequence-3') -ReferenceTime $thirdReviewClock
$sequence3 = Get-Content -Raw -LiteralPath $sequence3Path | ConvertFrom-Json
if (
    [int]$sequence3.review.sequence -ne 3 -or
    [int]$sequence3.previousCustodyReviewEvidence.reviewSequence -ne 2 -or
    [string]$sequence3.previousCustodyReviewEvidence.evidenceType -ne 'recurring-production-assurance-custody-review' -or
    [string]$sequence3.rootCustodyEvidence.sha256 -ne [string]$sequence2.rootCustodyEvidence.sha256
) {
    throw 'A later recurring custody review did not extend the exact previous chain.'
}

$fourthReviewClock = ([DateTimeOffset]$sequence3.schedule.nextReviewDueAtUtc).ToUniversalTime()
$sequence4Path = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $sequence3Path -OutputDirectory (Join-Path $testRoot 'passed-sequence-4') -ReferenceTime $fourthReviewClock
$sequence4 = Get-Content -Raw -LiteralPath $sequence4Path | ConvertFrom-Json
if ([int]$sequence4.review.sequence -ne 4 -or [string]$sequence4.outcome -ne 'passed') {
    throw 'Recurring custody review sequence 4 did not preserve the passed chain.'
}

$fifthReviewClock = ([DateTimeOffset]$sequence4.schedule.nextReviewDueAtUtc).ToUniversalTime()
$retentionRenewalPath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $sequence4Path -OutputDirectory (Join-Path $testRoot 'retention-renewal') -ReferenceTime $fifthReviewClock
$retentionRenewal = Get-Content -Raw -LiteralPath $retentionRenewalPath | ConvertFrom-Json
if (
    [int]$retentionRenewal.review.sequence -ne 5 -or
    [bool]$retentionRenewal.retention.remainingMeetsPolicy -ne $false -or
    [bool]$retentionRenewal.schedule.nextReviewWithinRetention -ne $false -or
    [string]$retentionRenewal.outcome -ne 'failed' -or
    [string]$retentionRenewal.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'Approaching retention expiry did not require renewal before another review.'
}
Assert-Rejected -FailureMessage 'Failed retention-renewal evidence was accepted as a later review boundary.' -Action {
    New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $retentionRenewalPath -OutputDirectory (Join-Path $testRoot 'failed-predecessor') -ReferenceTime ([DateTimeOffset]$retentionRenewal.schedule.nextReviewDueAtUtc) | Out-Null
}

$lateReviewPath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'late-review') -ReferenceTime $secondReviewClock.AddHours(25)
$lateReview = Get-Content -Raw -LiteralPath $lateReviewPath | ConvertFrom-Json
if (
    [bool]$lateReview.review.onTime -ne $false -or
    [string]$lateReview.outcome -ne 'failed' -or
    [string]$lateReview.decision.nextAction -ne 'escalate-missed-custody-review'
) {
    throw 'A late recurring custody review did not fail continuity and require escalation.'
}

$missingArchivePath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'missing-archive') -ReferenceTime $secondReviewClock -ArchiveAvailabilityStatus missing
$missingArchive = Get-Content -Raw -LiteralPath $missingArchivePath | ConvertFrom-Json
if ([string]$missingArchive.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing recurring archive evidence did not require restoration and investigation.'
}

$inactiveRetentionPath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'inactive-retention') -ReferenceTime $secondReviewClock -RetentionPolicyStatus inactive
$inactiveRetention = Get-Content -Raw -LiteralPath $inactiveRetentionPath | ConvertFrom-Json
if ([string]$inactiveRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'Inactive retention did not require renewal.'
}

$overbroadAccessPath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'overbroad-access') -ReferenceTime $secondReviewClock -AccessControlStatus overbroad
$overbroadAccess = Get-Content -Raw -LiteralPath $overbroadAccessPath | ConvertFrom-Json
if ([string]$overbroadAccess.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Overbroad recurring archive access did not require investigation.'
}

$failedRestorePath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-restore') -ReferenceTime $secondReviewClock -RestoreVerificationStatus failed
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed recurring restore verification did not require repair.'
}

$unknownReviewPath = New-TestRecurringCustodyReviewEvidence -PreviousEvidencePath $scheduledEvidencePath -OutputDirectory (Join-Path $testRoot 'unknown') -ReferenceTime $secondReviewClock -EvidenceInventoryStatus unknown
$unknownReview = Get-Content -Raw -LiteralPath $unknownReviewPath | ConvertFrom-Json
if (
    [string]$unknownReview.outcome -ne 'unknown' -or
    [string]$unknownReview.decision.nextAction -ne 'investigate-and-refresh-evidence'
) {
    throw 'Unknown recurring custody-review evidence did not fail closed.'
}

Assert-RecurringCustodyGateRejected -EvidencePath $missingArchivePath -ReferenceTime $secondReviewClock -FailureMessage 'The recurring custody gate accepted missing archive evidence.'

$originalEvidence = [System.IO.File]::ReadAllText($sequence2Path)
$reviewTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['review']['sequence'] = 4
    [System.IO.File]::WriteAllText($sequence2Path, (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-evidence.ps1') -EvidencePath $sequence2Path -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
    }
    catch {
        $reviewTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($sequence2Path, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $reviewTamperingRejected) {
    throw 'Recurring custody review sequence tampering was not rejected.'
}

$originalPrevious = [System.IO.File]::ReadAllText($scheduledEvidencePath)
$previousTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($scheduledEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-evidence.ps1') -EvidencePath $sequence2Path -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null
    }
    catch {
        $previousTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($scheduledEvidencePath, $originalPrevious, [System.Text.UTF8Encoding]::new($false))
}
if (-not $previousTamperingRejected) {
    throw 'Changed previous custody review evidence was not rejected.'
}

Assert-RecurringCustodyGateRejected -EvidencePath $sequence2Path -ReferenceTime $secondReviewClock.AddMinutes(61) -FailureMessage 'The recurring custody review gate accepted stale evidence.'
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-gate.ps1') -EvidencePath $sequence2Path -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $secondReviewClock.ToString('o') 6>$null

Write-Host 'Recurring production assurance custody review contract passed.'
