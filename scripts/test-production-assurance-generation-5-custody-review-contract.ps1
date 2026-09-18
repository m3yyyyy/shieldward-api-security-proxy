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

function New-TestGeneration4CustodyReview {
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
        ScheduledReviewReference = 'GENERATION-4-CUSTODY-REVIEW-004'
        ArchiveInventoryReference = 'GENERATION-4-ARCHIVE-INVENTORY-004'
        ObjectLockReference = 'GENERATION-4-OBJECT-LOCK-004'
        RetentionPolicyReference = 'GENERATION-4-RETENTION-POLICY-004'
        EncryptionReference = 'GENERATION-4-ENCRYPTION-004'
        AccessReviewReference = 'GENERATION-4-ACCESS-REVIEW-004'
        RestoreTestReference = 'GENERATION-4-RESTORE-TEST-004'
        ReviewedBy = 'Independent Generation-5 Custody Reviewer'
        MaxBaselineAgeHours = 2208
        MaxReviewAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-review-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'generation-5-custody-review-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-4-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-4-retention-renewal-evidence-contract'
$baselineRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-custody-baseline-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-custody-review-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/generation-4-retention-renewal-CHG-CUSTODY-RENEWAL-004.json'
$renewalEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'generation-4-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baselinePath = (Get-ChildItem -LiteralPath (Join-Path $baselineRoot 'passed') -Filter 'generation-5-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$reviewClock = ([DateTimeOffset]$baseline.generation5Baseline.nextReviewDueAtUtc).ToUniversalTime()
$commonArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ReferenceTime = $reviewClock
    ReviewCompletedAt = $reviewClock
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'passed'
$passedEvidencePath = New-TestGeneration4CustodyReview @caseArguments

$validationArguments = @{
    EvidencePath = $passedEvidencePath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $reviewClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-evidence.ps1') @validationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-gate.ps1') @validationArguments 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.generation5CustodyBaseline.generation -ne 5 -or
    [int]$passedEvidence.generation5CustodyBaseline.renewalSequence -ne 4 -or
    [int]$passedEvidence.review.sequence -ne 13 -or
    [int]$passedEvidence.review.previousHeadSequence -ne 12 -or
    [bool]$passedEvidence.review.onTime -ne $true -or
    [string]$passedEvidence.inheritedLineage.generation4BaselineSha256 -ne [string]$baseline.inheritedLineage.generation4BaselineSha256 -or
    ($passedEvidence.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -ne ($baseline.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -or
    [string]$passedEvidence.inheritedLineage.generation4ReviewChainDigest -ne [string]$baseline.inheritedLineage.generation4ReviewChainDigest -or
    [bool]$passedEvidence.decision.baselineLinkValid -ne $true -or
    [bool]$passedEvidence.decision.inheritedLineagePreserved -ne $true -or
    [bool]$passedEvidence.decision.custodyContinuityProven -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-generation-5-custody-reviews'
) {
    throw 'A healthy generation-5 sequence-13 review did not produce passed custody evidence.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'late-review'
$caseArguments.ReferenceTime = $reviewClock.AddHours(25)
$caseArguments.ReviewCompletedAt = $reviewClock.AddHours(25)
$lateEvidencePath = New-TestGeneration4CustodyReview @caseArguments
$lateEvidence = Get-Content -Raw -LiteralPath $lateEvidencePath | ConvertFrom-Json
if ([string]$lateEvidence.outcome -ne 'failed' -or [string]$lateEvidence.decision.nextAction -ne 'escalate-missed-generation-5-custody-review') {
    throw 'A late generation-5 custody review did not require escalation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'missing-archive'
$caseArguments.ArchiveAvailabilityStatus = 'missing'
$missingArchivePath = New-TestGeneration4CustodyReview @caseArguments
$missingArchive = Get-Content -Raw -LiteralPath $missingArchivePath | ConvertFrom-Json
if ([string]$missingArchive.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing generation-5 custody evidence did not require restoration and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'inactive-retention'
$caseArguments.RetentionPolicyStatus = 'inactive'
$inactiveRetentionPath = New-TestGeneration4CustodyReview @caseArguments
$inactiveRetention = Get-Content -Raw -LiteralPath $inactiveRetentionPath | ConvertFrom-Json
if ([string]$inactiveRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'Inactive generation-5 retention did not stop custody review continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-encryption'
$caseArguments.EncryptionStatus = 'failed'
$failedEncryptionPath = New-TestGeneration4CustodyReview @caseArguments
$failedEncryption = Get-Content -Raw -LiteralPath $failedEncryptionPath | ConvertFrom-Json
if ([string]$failedEncryption.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed generation-5 archive encryption did not require restriction and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-restore'
$caseArguments.RestoreVerificationStatus = 'failed'
$failedRestorePath = New-TestGeneration4CustodyReview @caseArguments
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed generation-5 restore verification did not require repair and retesting.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'unknown'
$caseArguments.ObjectLockStatus = 'unknown'
$unknownPath = New-TestGeneration4CustodyReview @caseArguments
$unknown = Get-Content -Raw -LiteralPath $unknownPath | ConvertFrom-Json
if ([string]$unknown.outcome -ne 'unknown' -or [string]$unknown.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown generation-5 custody controls did not fail closed.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'outside-retention'
$caseArguments.NextReviewIntervalDays = 1000
$outsideRetentionPath = New-TestGeneration4CustodyReview @caseArguments
$outsideRetention = Get-Content -Raw -LiteralPath $outsideRetentionPath | ConvertFrom-Json
if ([bool]$outsideRetention.schedule.nextReviewWithinRetention -ne $false -or [string]$outsideRetention.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'A next generation-5 review outside retention did not stop continuation.'
}

Assert-Rejected -FailureMessage 'The sequence-13 custody-review gate accepted missing archive evidence.' -Action {
    $failedGateArguments = $validationArguments.Clone()
    $failedGateArguments.EvidencePath = $missingArchivePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-gate.ps1') @failedGateArguments 6>$null
}

$wrongContextArguments = $validationArguments.Clone()
$wrongContextArguments.ExpectedProductionContext = 'wrong-production-context'
$wrongContextArguments.Remove('ReferenceTimeUtc')
Assert-Rejected -FailureMessage 'Sequence-7 custody-review evidence accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-evidence.ps1') @wrongContextArguments 6>$null
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['review']['sequence'] = 14
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-evidence.ps1') @validationArguments 6>$null
    }
    catch { $evidenceTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) { throw 'Sequence-13 custody-review evidence tampering was not rejected.' }

$originalBaseline = [System.IO.File]::ReadAllText($baselinePath)
$baselineTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($baselinePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-evidence.ps1') @validationArguments 6>$null
    }
    catch { $baselineTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($baselinePath, $originalBaseline, [System.Text.UTF8Encoding]::new($false))
}
if (-not $baselineTamperingRejected) { throw 'Changed generation-5 baseline was not rejected by sequence-13 review evidence.' }

$staleGateArguments = $validationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $reviewClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxEvidenceAgeMinutes = 60
Assert-Rejected -FailureMessage 'The sequence-13 custody-review gate accepted stale evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-gate.ps1') @staleGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-gate.ps1') @validationArguments 6>$null

Write-Host 'Generation-5 production assurance custody-review evidence contract passed.'
