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

function New-TestGeneration6CustodyReview {
    param(
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
        [string]$RestoreVerificationStatus = 'passed',
        [int]$NextReviewIntervalDays = 90
    )

    $arguments = @{
        BaselinePath = $BaselinePath
        RenewalEvidencePath = $RenewalEvidencePath
        PlanPath = $PlanPath
        ExpectedProductionContext = 'production-contract'
        ReviewCompletedAtUtc = $ReviewCompletedAt
        CompletionGraceHours = 24
        NextReviewIntervalDays = $NextReviewIntervalDays
        MinimumRetentionRemainingDays = 90
        ArchiveAvailabilityStatus = $ArchiveAvailabilityStatus
        EvidenceInventoryStatus = $EvidenceInventoryStatus
        ObjectLockStatus = $ObjectLockStatus
        RetentionPolicyStatus = $RetentionPolicyStatus
        EncryptionStatus = $EncryptionStatus
        AccessControlStatus = $AccessControlStatus
        RestoreVerificationStatus = $RestoreVerificationStatus
        ScheduledReviewReference = 'GENERATION-6-CUSTODY-REVIEW-006'
        ArchiveInventoryReference = 'GENERATION-6-ARCHIVE-INVENTORY-006'
        ObjectLockReference = 'GENERATION-6-OBJECT-LOCK-006'
        RetentionPolicyReference = 'GENERATION-6-RETENTION-POLICY-006'
        EncryptionReference = 'GENERATION-6-ENCRYPTION-006'
        AccessReviewReference = 'GENERATION-6-ACCESS-REVIEW-006'
        RestoreTestReference = 'GENERATION-6-RESTORE-TEST-006'
        ReviewedBy = 'Independent Generation-6 Custody Reviewer'
        MaxBaselineAgeHours = 2208
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-6-custody-review-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'generation-6-custody-review-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-retention-renewal-evidence-contract'
$baselineRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-custody-baseline-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-custody-review-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-baseline-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/generation-5-retention-renewal-CHG-CUSTODY-RENEWAL-005.json'
$renewalEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'generation-5-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baselinePath = (Get-ChildItem -LiteralPath (Join-Path $baselineRoot 'passed') -Filter 'generation-6-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$reviewClock = ([DateTimeOffset]$baseline.generation6Baseline.nextReviewDueAtUtc).ToUniversalTime()
$commonArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ReferenceTime = $reviewClock
    ReviewCompletedAt = $reviewClock
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'passed'
$passedEvidencePath = New-TestGeneration6CustodyReview @caseArguments

$validationArguments = @{
    EvidencePath = $passedEvidencePath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $reviewClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-evidence.ps1') @validationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-gate.ps1') @validationArguments 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.generation6CustodyBaseline.generation -ne 6 -or
    [int]$passedEvidence.generation6CustodyBaseline.renewalSequence -ne 5 -or
    [int]$passedEvidence.review.sequence -ne 16 -or
    [int]$passedEvidence.review.previousHeadSequence -ne 15 -or
    [bool]$passedEvidence.review.onTime -ne $true -or
    [string]$passedEvidence.inheritedLineage.generation5BaselineSha256 -ne [string]$baseline.inheritedLineage.generation5BaselineSha256 -or
    ($passedEvidence.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -ne ($baseline.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -or
    [string]$passedEvidence.inheritedLineage.generation5ReviewChainDigest -ne [string]$baseline.inheritedLineage.generation5ReviewChainDigest -or
    [bool]$passedEvidence.decision.baselineLinkValid -ne $true -or
    [bool]$passedEvidence.decision.inheritedLineagePreserved -ne $true -or
    [bool]$passedEvidence.decision.custodyContinuityProven -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-generation-6-custody-reviews'
) {
    throw 'A healthy generation-6 sequence-16 review did not produce passed custody evidence.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'late-review'
$caseArguments.ReferenceTime = $reviewClock.AddHours(25)
$caseArguments.ReviewCompletedAt = $reviewClock.AddHours(25)
$lateEvidencePath = New-TestGeneration6CustodyReview @caseArguments
$lateEvidence = Get-Content -Raw -LiteralPath $lateEvidencePath | ConvertFrom-Json
if ([string]$lateEvidence.outcome -ne 'failed' -or [string]$lateEvidence.decision.nextAction -ne 'escalate-missed-generation-6-custody-review') {
    throw 'A late generation-6 custody review did not require escalation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'missing-archive'
$caseArguments.ArchiveAvailabilityStatus = 'missing'
$missingArchivePath = New-TestGeneration6CustodyReview @caseArguments
$missingArchive = Get-Content -Raw -LiteralPath $missingArchivePath | ConvertFrom-Json
if ([string]$missingArchive.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing generation-6 custody evidence did not require restoration and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'inactive-retention'
$caseArguments.RetentionPolicyStatus = 'inactive'
$inactiveRetentionPath = New-TestGeneration6CustodyReview @caseArguments
$inactiveRetention = Get-Content -Raw -LiteralPath $inactiveRetentionPath | ConvertFrom-Json
if ([string]$inactiveRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'Inactive generation-6 retention did not stop custody review continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-encryption'
$caseArguments.EncryptionStatus = 'failed'
$failedEncryptionPath = New-TestGeneration6CustodyReview @caseArguments
$failedEncryption = Get-Content -Raw -LiteralPath $failedEncryptionPath | ConvertFrom-Json
if ([string]$failedEncryption.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed generation-6 archive encryption did not require restriction and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-restore'
$caseArguments.RestoreVerificationStatus = 'failed'
$failedRestorePath = New-TestGeneration6CustodyReview @caseArguments
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed generation-6 restore verification did not require repair and retesting.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'unknown'
$caseArguments.ObjectLockStatus = 'unknown'
$unknownPath = New-TestGeneration6CustodyReview @caseArguments
$unknown = Get-Content -Raw -LiteralPath $unknownPath | ConvertFrom-Json
if ([string]$unknown.outcome -ne 'unknown' -or [string]$unknown.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown generation-6 custody controls did not fail closed.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'outside-retention'
$caseArguments.NextReviewIntervalDays = 1000
$outsideRetentionPath = New-TestGeneration6CustodyReview @caseArguments
$outsideRetention = Get-Content -Raw -LiteralPath $outsideRetentionPath | ConvertFrom-Json
if ([bool]$outsideRetention.schedule.nextReviewWithinRetention -ne $false -or [string]$outsideRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'A next generation-6 review outside retention did not stop continuation.'
}

Assert-Rejected -FailureMessage 'The sequence-16 custody-review gate accepted missing archive evidence.' -Action {
    $failedGateArguments = $validationArguments.Clone()
    $failedGateArguments.EvidencePath = $missingArchivePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-gate.ps1') @failedGateArguments 6>$null
}

$wrongContextArguments = $validationArguments.Clone()
$wrongContextArguments.ExpectedProductionContext = 'wrong-production-context'
$wrongContextArguments.Remove('ReferenceTimeUtc')
Assert-Rejected -FailureMessage 'Sequence-16 custody-review evidence accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-evidence.ps1') @wrongContextArguments 6>$null
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['review']['sequence'] = 17
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-evidence.ps1') @validationArguments 6>$null
    }
    catch { $evidenceTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) { throw 'Sequence-16 custody-review evidence tampering was not rejected.' }

$originalBaseline = [System.IO.File]::ReadAllText($baselinePath)
$baselineTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($baselinePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-evidence.ps1') @validationArguments 6>$null
    }
    catch { $baselineTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($baselinePath, $originalBaseline, [System.Text.UTF8Encoding]::new($false))
}
if (-not $baselineTamperingRejected) { throw 'Changed generation-6 baseline was not rejected by sequence-16 review evidence.' }

$staleGateArguments = $validationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $reviewClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxEvidenceAgeMinutes = 60
Assert-Rejected -FailureMessage 'The sequence-16 custody-review gate accepted stale evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-gate.ps1') @staleGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-review-gate.ps1') @validationArguments 6>$null

Write-Host 'Generation-6 production assurance custody-review evidence contract passed.'
