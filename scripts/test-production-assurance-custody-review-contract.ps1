[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestCustodyReviewEvidence {
    param(
        [Parameter(Mandatory)][string]$CustodyEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [string]$ArchiveAvailabilityStatus = 'available',
        [string]$EvidenceInventoryStatus = 'complete',
        [string]$ObjectLockStatus = 'enforced',
        [string]$RetentionPolicyStatus = 'active',
        [string]$EncryptionStatus = 'verified',
        [string]$AccessControlStatus = 'least-privilege',
        [string]$RestoreVerificationStatus = 'passed',
        [int]$NextReviewIntervalDays = 90,
        [int]$MinimumRetentionRemainingDays = 90,
        [DateTimeOffset]$ScheduledReviewDueAt = [DateTimeOffset]::MinValue
    )

    $custody = Get-Content -Raw -LiteralPath $CustodyEvidencePath | ConvertFrom-Json
    if ($ScheduledReviewDueAt -eq [DateTimeOffset]::MinValue) {
        $ScheduledReviewDueAt = ([DateTimeOffset]$custody.collectedAtUtc).ToUniversalTime()
    }
    $arguments = @{
        CustodyEvidencePath = $CustodyEvidencePath
        ExpectedProductionContext = 'production-contract'
        ScheduledReviewDueAtUtc = $ScheduledReviewDueAt
        ReviewCompletedAtUtc = $ReferenceTime
        CompletionGraceHours = 24
        NextReviewIntervalDays = $NextReviewIntervalDays
        MinimumRetentionRemainingDays = $MinimumRetentionRemainingDays
        ArchiveAvailabilityStatus = $ArchiveAvailabilityStatus
        EvidenceInventoryStatus = $EvidenceInventoryStatus
        ObjectLockStatus = $ObjectLockStatus
        RetentionPolicyStatus = $RetentionPolicyStatus
        EncryptionStatus = $EncryptionStatus
        AccessControlStatus = $AccessControlStatus
        RestoreVerificationStatus = $RestoreVerificationStatus
        ScheduledReviewReference = 'CUSTODY-REVIEW-SCHEDULE-' + [string]$custody.chainAuditEvidence.headReviewSequence
        ArchiveInventoryReference = 'CUSTODY-REVIEW-INVENTORY-' + [string]$custody.incidentId
        ObjectLockReference = 'CUSTODY-REVIEW-OBJECT-LOCK-' + [string]$custody.incidentId
        RetentionPolicyReference = 'CUSTODY-REVIEW-RETENTION-' + [string]$custody.incidentId
        EncryptionReference = 'CUSTODY-REVIEW-ENCRYPTION-' + [string]$custody.incidentId
        AccessReviewReference = 'CUSTODY-REVIEW-ACCESS-' + [string]$custody.incidentId
        RestoreTestReference = 'CUSTODY-REVIEW-RESTORE-' + [string]$custody.incidentId
        ReviewedBy = 'Independent Custody Reviewer'
        MaxCustodyEvidenceAgeHours = 2208
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-custody-review-evidence.ps1') @arguments 3>$null 6>$null

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

function Assert-CustodyReviewGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-gate.ps1') -EvidencePath $EvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$custodyRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-review-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-custody-contract.ps1') 6>$null

$custodyEvidencePath = (Get-ChildItem -LiteralPath $custodyRoot -Filter 'custody-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$custody = Get-Content -Raw -LiteralPath $custodyEvidencePath | ConvertFrom-Json
$reviewClock = ([DateTimeOffset]$custody.collectedAtUtc).ToUniversalTime()

$passedEvidencePath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'passed') -ReferenceTime $reviewClock
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [bool]$passedEvidence.review.onTime -ne $true -or
    [bool]$passedEvidence.retention.remainingMeetsPolicy -ne $true -or
    [bool]$passedEvidence.schedule.nextReviewWithinRetention -ne $true -or
    [bool]$passedEvidence.decision.custodyLinkValid -ne $true -or
    [bool]$passedEvidence.decision.custodyContinuityProven -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy scheduled custody review did not prove custody continuity.'
}

$lateReviewPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'late-review') -ReferenceTime $reviewClock.AddHours(25)
$lateReview = Get-Content -Raw -LiteralPath $lateReviewPath | ConvertFrom-Json
if (
    [bool]$lateReview.review.onTime -ne $false -or
    [string]$lateReview.outcome -ne 'failed' -or
    [string]$lateReview.decision.nextAction -ne 'escalate-missed-custody-review'
) {
    throw 'A late custody review did not fail continuity and require escalation.'
}

$missingArchivePath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'missing-archive') -ReferenceTime $reviewClock -ArchiveAvailabilityStatus missing
$missingArchive = Get-Content -Raw -LiteralPath $missingArchivePath | ConvertFrom-Json
if ([string]$missingArchive.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing archive evidence did not require restoration and investigation.'
}

$incompleteInventoryPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'incomplete-inventory') -ReferenceTime $reviewClock -EvidenceInventoryStatus incomplete
$incompleteInventory = Get-Content -Raw -LiteralPath $incompleteInventoryPath | ConvertFrom-Json
if ([string]$incompleteInventory.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'An incomplete archive inventory did not fail closed.'
}

$shortRetentionPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'short-retention') -ReferenceTime $reviewClock -MinimumRetentionRemainingDays 400
$shortRetention = Get-Content -Raw -LiteralPath $shortRetentionPath | ConvertFrom-Json
if (
    [bool]$shortRetention.retention.remainingMeetsPolicy -ne $false -or
    [string]$shortRetention.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'Insufficient remaining retention did not require renewal.'
}

$outsideRetentionPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'outside-retention') -ReferenceTime $reviewClock -NextReviewIntervalDays 365
$outsideRetention = Get-Content -Raw -LiteralPath $outsideRetentionPath | ConvertFrom-Json
if (
    [bool]$outsideRetention.schedule.nextReviewWithinRetention -ne $false -or
    [string]$outsideRetention.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'A next review outside retention did not require renewal.'
}

$failedEncryptionPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-encryption') -ReferenceTime $reviewClock -EncryptionStatus failed
$failedEncryption = Get-Content -Raw -LiteralPath $failedEncryptionPath | ConvertFrom-Json
if ([string]$failedEncryption.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed encryption did not require access restriction.'
}

$failedRestorePath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-restore') -ReferenceTime $reviewClock -RestoreVerificationStatus failed
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'A failed restore review did not require archive repair.'
}

$unknownReviewPath = New-TestCustodyReviewEvidence -CustodyEvidencePath $custodyEvidencePath -OutputDirectory (Join-Path $testRoot 'unknown') -ReferenceTime $reviewClock -ObjectLockStatus unknown
$unknownReview = Get-Content -Raw -LiteralPath $unknownReviewPath | ConvertFrom-Json
if (
    [string]$unknownReview.outcome -ne 'unknown' -or
    [string]$unknownReview.decision.nextAction -ne 'investigate-and-refresh-evidence'
) {
    throw 'Unknown custody-review evidence did not fail closed.'
}

Assert-CustodyReviewGateRejected -EvidencePath $missingArchivePath -ReferenceTime $reviewClock -FailureMessage 'The custody review gate accepted missing archive evidence.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$reviewTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['decision']['custodyContinuityProven'] = $false
    [System.IO.File]::WriteAllText($passedEvidencePath, (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null
    }
    catch {
        $reviewTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $reviewTamperingRejected) {
    throw 'Custody review evidence tampering was not rejected.'
}

$originalCustody = [System.IO.File]::ReadAllText($custodyEvidencePath)
$custodyTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($custodyEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null
    }
    catch {
        $custodyTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($custodyEvidencePath, $originalCustody, [System.Text.UTF8Encoding]::new($false))
}
if (-not $custodyTamperingRejected) {
    throw 'Changed custody evidence was not rejected by the scheduled review.'
}

Assert-CustodyReviewGateRejected -EvidencePath $passedEvidencePath -ReferenceTime $reviewClock.AddMinutes(61) -FailureMessage 'The custody review gate accepted stale evidence.'
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $reviewClock.ToString('o') 6>$null

Write-Host 'Scheduled production assurance custody review contract passed.'
