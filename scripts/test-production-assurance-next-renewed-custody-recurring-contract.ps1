[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Rejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$FailureMessage)

    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw $FailureMessage }
}

function New-TestRecurringNextRenewedCustodyReview {
    param(
        [Parameter(Mandatory)][string]$PreviousReviewEvidencePath,
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][string]$RenewalEvidencePath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][DateTimeOffset]$ReviewCompletedAt,
        [string]$ArchiveAvailabilityStatus = 'available',
        [string]$EvidenceInventoryStatus = 'complete',
        [string]$ObjectLockStatus = 'enforced',
        [string]$RetentionPolicyStatus = 'active',
        [string]$EncryptionStatus = 'verified',
        [string]$AccessControlStatus = 'least-privilege',
        [string]$RestoreVerificationStatus = 'passed'
    )

    $arguments = @{
        PreviousReviewEvidencePath = $PreviousReviewEvidencePath
        BaselinePath = $BaselinePath
        RenewalEvidencePath = $RenewalEvidencePath
        PlanPath = $PlanPath
        ExpectedProductionContext = 'production-contract'
        ReviewCompletedAtUtc = $ReviewCompletedAt
        CompletionGraceHours = 24
        ArchiveAvailabilityStatus = $ArchiveAvailabilityStatus
        EvidenceInventoryStatus = $EvidenceInventoryStatus
        ObjectLockStatus = $ObjectLockStatus
        RetentionPolicyStatus = $RetentionPolicyStatus
        EncryptionStatus = $EncryptionStatus
        AccessControlStatus = $AccessControlStatus
        RestoreVerificationStatus = $RestoreVerificationStatus
        PreviousReviewGateReference = 'NEXT-RENEWED-CUSTODY-GATE-004'
        ScheduledReviewReference = 'NEXT-RENEWED-CUSTODY-REVIEW-004'
        ArchiveInventoryReference = 'NEXT-RENEWED-ARCHIVE-INVENTORY-004'
        ObjectLockReference = 'NEXT-RENEWED-OBJECT-LOCK-004'
        RetentionPolicyReference = 'NEXT-RENEWED-RETENTION-POLICY-004'
        EncryptionReference = 'NEXT-RENEWED-ENCRYPTION-004'
        AccessReviewReference = 'NEXT-RENEWED-ACCESS-REVIEW-004'
        RestoreTestReference = 'NEXT-RENEWED-RESTORE-TEST-004'
        ReviewedBy = 'Independent Recurring Generation-3 Custody Reviewer'
        MaxPreviousEvidenceAgeHours = 2208
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-next-renewed-custody-recurring-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'next-renewed-custody-review-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-evidence-contract'
$baselineRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-baseline-contract'
$firstReviewRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-review-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-recurring-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-review-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/renewed-retention-renewal-CHG-CUSTODY-RENEWAL-002.json'
$renewalEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'renewed-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baselinePath = (Get-ChildItem -LiteralPath (Join-Path $baselineRoot 'passed') -Filter 'next-renewed-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$firstReviewPath = (Get-ChildItem -LiteralPath (Join-Path $firstReviewRoot 'passed') -Filter 'next-renewed-custody-review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$firstReview = Get-Content -Raw -LiteralPath $firstReviewPath | ConvertFrom-Json
$firstRecurringClock = ([DateTimeOffset]$firstReview.schedule.nextReviewDueAtUtc).ToUniversalTime()
$commonArguments = @{
    PreviousReviewEvidencePath = $firstReviewPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ReferenceTime = $firstRecurringClock
    ReviewCompletedAt = $firstRecurringClock
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'passed-first'
$firstRecurringPath = New-TestRecurringNextRenewedCustodyReview @caseArguments

$firstValidationArguments = @{
    EvidencePath = $firstRecurringPath
    PreviousReviewEvidencePath = $firstReviewPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $firstRecurringClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @firstValidationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-gate.ps1') @firstValidationArguments 6>$null

$firstRecurring = Get-Content -Raw -LiteralPath $firstRecurringPath | ConvertFrom-Json
if (
    [string]$firstRecurring.outcome -ne 'passed' -or
    [int]$firstRecurring.nextRenewedCustodyBaseline.generation -ne 3 -or
    [int]$firstRecurring.nextRenewedCustodyBaseline.renewalSequence -ne 2 -or
    [int]$firstRecurring.review.sequence -ne 8 -or
    [int]$firstRecurring.review.previousSequence -ne 7 -or
    [string]$firstRecurring.previousReviewEvidence.evidenceType -ne 'next-renewed-production-assurance-custody-review' -or
    [bool]$firstRecurring.decision.baselineLinkValid -ne $true -or
    [bool]$firstRecurring.decision.predecessorLinkValid -ne $true -or
    [bool]$firstRecurring.decision.inheritedLineagePreserved -ne $true -or
    [bool]$firstRecurring.decision.custodyContinuityProven -ne $true -or
    [string]$firstRecurring.decision.nextAction -ne 'continue-next-renewed-custody-reviews'
) {
    throw 'A healthy recurring generation-3 review did not continue sequence 7 as sequence 8.'
}

$secondRecurringClock = ([DateTimeOffset]$firstRecurring.schedule.nextReviewDueAtUtc).ToUniversalTime()
$secondArguments = @{
    PreviousReviewEvidencePath = $firstRecurringPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    OutputDirectory = Join-Path $testRoot 'passed-second'
    ReferenceTime = $secondRecurringClock
    ReviewCompletedAt = $secondRecurringClock
}
$secondRecurringPath = New-TestRecurringNextRenewedCustodyReview @secondArguments
$secondValidationArguments = $firstValidationArguments.Clone()
$secondValidationArguments.EvidencePath = $secondRecurringPath
$secondValidationArguments.PreviousReviewEvidencePath = $firstRecurringPath
$secondValidationArguments.ReferenceTimeUtc = $secondRecurringClock.ToString('o')
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @secondValidationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-gate.ps1') @secondValidationArguments 6>$null
$secondRecurring = Get-Content -Raw -LiteralPath $secondRecurringPath | ConvertFrom-Json
if (
    [int]$secondRecurring.review.sequence -ne 9 -or
    [int]$secondRecurring.review.previousSequence -ne 8 -or
    [string]$secondRecurring.previousReviewEvidence.evidenceType -ne 'recurring-next-renewed-production-assurance-custody-review'
) {
    throw 'A subsequent recurring generation-3 review did not derive sequence 9 from sequence 8.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'late-review'
$caseArguments.ReferenceTime = $firstRecurringClock.AddHours(25)
$caseArguments.ReviewCompletedAt = $firstRecurringClock.AddHours(25)
$lateEvidencePath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$lateEvidence = Get-Content -Raw -LiteralPath $lateEvidencePath | ConvertFrom-Json
if ([string]$lateEvidence.outcome -ne 'failed' -or [string]$lateEvidence.decision.nextAction -ne 'escalate-missed-next-renewed-custody-review') {
    throw 'A late recurring generation-3 custody review did not require escalation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'missing-archive'
$caseArguments.ArchiveAvailabilityStatus = 'missing'
$missingArchivePath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$missingArchive = Get-Content -Raw -LiteralPath $missingArchivePath | ConvertFrom-Json
if ([string]$missingArchive.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing recurring generation-3 custody evidence did not require restoration and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'inactive-retention'
$caseArguments.RetentionPolicyStatus = 'inactive'
$inactiveRetentionPath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$inactiveRetention = Get-Content -Raw -LiteralPath $inactiveRetentionPath | ConvertFrom-Json
if ([string]$inactiveRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'Inactive retention did not stop recurring generation-3 review continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-encryption'
$caseArguments.EncryptionStatus = 'failed'
$failedEncryptionPath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$failedEncryption = Get-Content -Raw -LiteralPath $failedEncryptionPath | ConvertFrom-Json
if ([string]$failedEncryption.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed generation-3 encryption did not require restriction and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-restore'
$caseArguments.RestoreVerificationStatus = 'failed'
$failedRestorePath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed generation-3 restore verification did not require repair and retesting.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'unknown'
$caseArguments.ObjectLockStatus = 'unknown'
$unknownPath = New-TestRecurringNextRenewedCustodyReview @caseArguments
$unknown = Get-Content -Raw -LiteralPath $unknownPath | ConvertFrom-Json
if ([string]$unknown.outcome -ne 'unknown' -or [string]$unknown.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown recurring generation-3 controls did not fail closed.'
}

Assert-Rejected -FailureMessage 'Failed generation-3 custody evidence was accepted as a recurring predecessor.' -Action {
    $failedPredecessorArguments = $commonArguments.Clone()
    $failedPredecessorArguments.PreviousReviewEvidencePath = $missingArchivePath
    $failedPredecessorArguments.ReferenceTime = ([DateTimeOffset]$missingArchive.schedule.nextReviewDueAtUtc).ToUniversalTime()
    $failedPredecessorArguments.ReviewCompletedAt = $failedPredecessorArguments.ReferenceTime
    $failedPredecessorArguments.OutputDirectory = Join-Path $testRoot 'failed-predecessor'
    New-TestRecurringNextRenewedCustodyReview @failedPredecessorArguments | Out-Null
}

Assert-Rejected -FailureMessage 'The recurring generation-3 gate accepted missing archive evidence.' -Action {
    $failedGateArguments = $firstValidationArguments.Clone()
    $failedGateArguments.EvidencePath = $missingArchivePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-gate.ps1') @failedGateArguments 6>$null
}

$wrongContextArguments = $firstValidationArguments.Clone()
$wrongContextArguments.ExpectedProductionContext = 'wrong-production-context'
$wrongContextArguments.Remove('ReferenceTimeUtc')
Assert-Rejected -FailureMessage 'Recurring generation-3 custody evidence accepted the wrong context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @wrongContextArguments 6>$null
}

$originalEvidence = [System.IO.File]::ReadAllText($firstRecurringPath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['review']['sequence'] = 9
    [System.IO.File]::WriteAllText($firstRecurringPath, (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @firstValidationArguments 6>$null
    }
    catch { $evidenceTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($firstRecurringPath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) { throw 'Recurring generation-3 custody evidence tampering was not rejected.' }

$originalPrevious = [System.IO.File]::ReadAllText($firstReviewPath)
$previousTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($firstReviewPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @firstValidationArguments 6>$null
    }
    catch { $previousTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($firstReviewPath, $originalPrevious, [System.Text.UTF8Encoding]::new($false))
}
if (-not $previousTamperingRejected) { throw 'Changed sequence-7 predecessor was not rejected by the recurring chain.' }

$staleGateArguments = $firstValidationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $firstRecurringClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxEvidenceAgeMinutes = 60
Assert-Rejected -FailureMessage 'The recurring generation-3 gate accepted stale evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-gate.ps1') @staleGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-gate.ps1') @firstValidationArguments 6>$null

Write-Host 'Recurring next renewed production assurance custody-review contract passed.'
