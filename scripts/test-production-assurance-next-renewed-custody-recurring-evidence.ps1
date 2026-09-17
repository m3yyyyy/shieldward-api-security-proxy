[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PreviousReviewEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

function Resolve-LocalStatePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Description must not be empty." }
    $resolved = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
    }
    if (-not $resolved.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be beneath the ignored .shieldward directory."
    }
    return $resolved
}

function Assert-Reference {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Description)

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 256 -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most 256 characters without control characters."
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha256.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Test-JsonEqual {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)
    return (($Left | ConvertTo-Json -Depth 9 -Compress) -eq ($Right | ConvertTo-Json -Depth 9 -Compress))
}

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Recurring generation-3 custody-review evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'recurring-next-renewed-production-assurance-custody-review'
) {
    throw 'The supplied recurring generation-3 custody-review evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext -or [string]$evidence.namespace -ne 'shieldward') {
    throw 'Recurring generation-3 custody-review evidence targets the wrong context or namespace.'
}

$resolvedPreviousPath = if ([string]::IsNullOrWhiteSpace($PreviousReviewEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.previousReviewEvidence.relativePath) -Description 'Recorded predecessor path'
}
else {
    Resolve-LocalStatePath -Path $PreviousReviewEvidencePath -Description 'PreviousReviewEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Recorded predecessor custody-review evidence is missing: $resolvedPreviousPath"
}
$previous = Get-Content -Raw -LiteralPath $resolvedPreviousPath | ConvertFrom-Json
$previousType = [string]$previous.evidenceType
$previousValidationArguments = @{
    EvidencePath = $resolvedPreviousPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) { $previousValidationArguments.BaselinePath = $BaselinePath }
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) { $previousValidationArguments.RenewalEvidencePath = $RenewalEvidencePath }
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $previousValidationArguments.PlanPath = $PlanPath }
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) { $previousValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc }
if ($previousType -eq 'next-renewed-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-review-evidence.ps1') @previousValidationArguments 6>$null
}
elseif ($previousType -eq 'recurring-next-renewed-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @previousValidationArguments 6>$null
}
else {
    throw "Recorded predecessor type '$previousType' is unsupported for generation 3."
}

$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
$previousCollectedAt = ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime()
if (
    $previousType -ne [string]$evidence.previousReviewEvidence.evidenceType -or
    $previousRelativePath -ne [string]$evidence.previousReviewEvidence.relativePath -or
    $previousHash -ne [string]$evidence.previousReviewEvidence.sha256 -or
    [string]$previous.integrityDigest -ne [string]$evidence.previousReviewEvidence.integrityDigest -or
    [string]$previous.review.linkDigest -ne [string]$evidence.previousReviewEvidence.linkDigest -or
    $previousCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.previousReviewEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$previous.review.sequence -ne [int]$evidence.previousReviewEvidence.reviewSequence -or
    [string]$evidence.previousReviewEvidence.outcome -ne 'passed' -or
    [bool]$evidence.previousReviewEvidence.custodyContinuityProven -ne $true
) {
    throw 'The exact passed predecessor no longer matches recurring generation-3 custody evidence.'
}
if (
    [string]$evidence.changeId -ne [string]$previous.changeId -or
    [string]$evidence.incidentId -ne [string]$previous.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$previous.closureChangeId -or
    -not (Test-JsonEqual -Left $evidence.candidate -Right $previous.candidate) -or
    -not (Test-JsonEqual -Left $evidence.nextRenewedCustodyBaseline -Right $previous.nextRenewedCustodyBaseline) -or
    -not (Test-JsonEqual -Left $evidence.renewalEvidence -Right $previous.renewalEvidence) -or
    -not (Test-JsonEqual -Left $evidence.inheritedLineage -Right $previous.inheritedLineage)
) {
    throw 'Recurring generation-3 custody evidence changed the production identity, baseline, renewal, or inherited lineage.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'archive availability'; Actual = [string]$evidence.controls.archiveAvailability; Allowed = @('available', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'evidence inventory'; Actual = [string]$evidence.controls.evidenceInventory; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'object lock'; Actual = [string]$evidence.controls.objectLock; Allowed = @('enforced', 'not-enforced', 'unknown') }
    [pscustomobject]@{ Name = 'retention policy'; Actual = [string]$evidence.controls.retentionPolicy; Allowed = @('active', 'inactive', 'unknown') }
    [pscustomobject]@{ Name = 'encryption'; Actual = [string]$evidence.controls.encryption; Allowed = @('verified', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access control'; Actual = [string]$evidence.controls.accessControl; Allowed = @('least-privilege', 'overbroad', 'unknown') }
    [pscustomobject]@{ Name = 'restore verification'; Actual = [string]$evidence.controls.restoreVerification; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "Recurring generation-3 custody evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.previousReviewGateReference; Description = 'Previous review gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.scheduledReviewReference; Description = 'Scheduled review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.archiveInventoryReference; Description = 'Archive inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.objectLockReference; Description = 'Object lock reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.retentionPolicyReference; Description = 'Retention policy reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.encryptionReference; Description = 'Encryption reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessReviewReference; Description = 'Access review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreTestReference; Description = 'Restore test reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'Reviewed by' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$expectedDueAt = ([DateTimeOffset]$previous.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
$previousCompletedAt = ([DateTimeOffset]$previous.review.completedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$previous.retention.untilUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$previousSequence = [int]$previous.review.sequence
$reviewSequence = $previousSequence + 1
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddHours(-1) -and
    $completedAt -le $expectedDueAt.AddHours([int]$evidence.review.completionGraceHours)
)
$nextReviewIntervalDays = [int]$previous.schedule.nextReviewIntervalDays
$minimumRetentionRemainingDays = [int]$previous.retention.minimumRemainingDays
$nextReviewDueAt = $completedAt.AddDays($nextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge $minimumRetentionRemainingDays
$nextReviewWithinRetention = $nextReviewDueAt -lt $retentionUntil
$previousAgeAtReview = $completedAt - $previousCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    [int]$evidence.review.sequence -ne $reviewSequence -or
    [int]$evidence.review.previousSequence -ne $previousSequence -or
    ([DateTimeOffset]$evidence.review.expectedDueAtUtc).ToUniversalTime().ToString('o') -ne $expectedDueAt.ToString('o') -or
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    $completedAt -lt $previousCompletedAt -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -lt 1 -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -gt 8760 -or
    $previousAgeAtReview.TotalHours -lt -1 -or
    $previousAgeAtReview.TotalHours -gt [int]$evidence.review.maxPreviousEvidenceAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5) -or
    ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $nextReviewWithinRetention -or
    ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime().ToString('o') -ne $retentionUntil.ToString('o') -or
    [int]$evidence.retention.minimumRemainingDays -ne $minimumRetentionRemainingDays -or
    [double]$evidence.retention.remainingDays -ne $retentionRemainingDays -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $retentionRemainingMeetsPolicy
) {
    throw 'Recurring generation-3 review timing, sequence, schedule, or retention calculation is invalid.'
}

$hasFailure = (
    -not $reviewOnTime -or
    [string]$evidence.controls.archiveAvailability -eq 'missing' -or
    [string]$evidence.controls.evidenceInventory -eq 'incomplete' -or
    [string]$evidence.controls.objectLock -eq 'not-enforced' -or
    [string]$evidence.controls.retentionPolicy -eq 'inactive' -or
    [string]$evidence.controls.encryption -eq 'failed' -or
    [string]$evidence.controls.accessControl -eq 'overbroad' -or
    [string]$evidence.controls.restoreVerification -eq 'failed' -or
    -not $retentionRemainingMeetsPolicy -or
    -not $nextReviewWithinRetention
)
$hasUnknown = @(
    [string]$evidence.controls.archiveAvailability,
    [string]$evidence.controls.evidenceInventory,
    [string]$evidence.controls.objectLock,
    [string]$evidence.controls.retentionPolicy,
    [string]$evidence.controls.encryption,
    [string]$evidence.controls.accessControl,
    [string]$evidence.controls.restoreVerification
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedContinuityProven = $expectedOutcome -eq 'passed'
$expectedNextAction = if ([string]$evidence.controls.archiveAvailability -eq 'missing' -or [string]$evidence.controls.evidenceInventory -eq 'incomplete') {
    'restore-evidence-and-investigate'
}
elseif ([string]$evidence.controls.objectLock -eq 'not-enforced' -or [string]$evidence.controls.retentionPolicy -eq 'inactive' -or -not $retentionRemainingMeetsPolicy -or -not $nextReviewWithinRetention) {
    'renew-retention-before-continuing'
}
elseif ([string]$evidence.controls.encryption -eq 'failed' -or [string]$evidence.controls.accessControl -eq 'overbroad') {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.controls.restoreVerification -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif (-not $reviewOnTime) {
    'escalate-missed-next-renewed-custody-review'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-next-renewed-custody-reviews'
}

$reviewLink = [ordered]@{
    previousReviewEvidenceSha256 = $previousHash
    previousReviewIntegrityDigest = [string]$previous.integrityDigest
    previousReviewLinkDigest = [string]$previous.review.linkDigest
    nextRenewedBaselineSha256 = [string]$previous.nextRenewedCustodyBaseline.sha256
    nextRenewedLineageDigest = [string]$previous.nextRenewedCustodyBaseline.lineageDigest
    previousReviewSequence = $previousSequence
    reviewSequence = $reviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
}
$reviewLinkDigest = Get-Sha256Text -Text ($reviewLink | ConvertTo-Json -Depth 4 -Compress)
if (
    [string]$evidence.review.linkDigest -ne $reviewLinkDigest -or
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.baselineLinkValid -ne $true -or
    [bool]$evidence.decision.predecessorLinkValid -ne $true -or
    [bool]$evidence.decision.inheritedLineagePreserved -ne $true -or
    [bool]$evidence.decision.custodyContinuityProven -ne $expectedContinuityProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'Recurring generation-3 linkage, outcome, or action is inconsistent.'
}

$integrity = [ordered]@{
    previousReviewEvidenceType = $previousType
    previousReviewEvidenceSha256 = $previousHash
    previousReviewIntegrityDigest = [string]$previous.integrityDigest
    previousReviewLinkDigest = [string]$previous.review.linkDigest
    previousReviewSequence = $previousSequence
    nextRenewedBaselineSha256 = [string]$previous.nextRenewedCustodyBaseline.sha256
    nextRenewedBaselineIntegrityDigest = [string]$previous.nextRenewedCustodyBaseline.integrityDigest
    nextRenewedLineageDigest = [string]$previous.nextRenewedCustodyBaseline.lineageDigest
    renewalEvidenceSha256 = [string]$previous.renewalEvidence.sha256
    renewalEvidenceIntegrityDigest = [string]$previous.renewalEvidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$previous.changeId
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    releaseVersion = [string]$previous.candidate.version
    sourceTag = [string]$previous.candidate.sourceTag
    controlPlaneImage = [string]$previous.candidate.controlPlaneImage
    edgeImage = [string]$previous.candidate.edgeImage
    policyVersion = [string]$previous.candidate.policyVersion
    previousBaselineSha256 = [string]$previous.inheritedLineage.renewedBaselineSha256
    previousBaselineIntegrityDigest = [string]$previous.inheritedLineage.renewedBaselineIntegrityDigest
    previousRenewedLineageDigest = [string]$previous.inheritedLineage.renewedLineageDigest
    previousRenewalEvidenceSha256 = [string]$previous.inheritedLineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$previous.inheritedLineage.previousRenewalEvidenceIntegrityDigest
    originalCustodySha256 = [string]$previous.inheritedLineage.originalCustodySha256
    originalCustodyIntegrityDigest = [string]$previous.inheritedLineage.originalCustodyIntegrityDigest
    originalCustodyChainDigest = [string]$previous.inheritedLineage.originalCustodyChainDigest
    priorReviewChainDigest = [string]$previous.inheritedLineage.priorReviewChainDigest
    previousRenewedReviewChainDigest = [string]$previous.inheritedLineage.renewedReviewChainDigest
    baselineGeneration = [int]$previous.nextRenewedCustodyBaseline.generation
    renewalSequence = [int]$previous.nextRenewedCustodyBaseline.renewalSequence
    previousCollectedAtUtc = $previousCollectedAt.ToString('o')
    retentionUntilUtc = $retentionUntil.ToString('o')
    reviewSequence = $reviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceHours = [int]$evidence.review.completionGraceHours
    reviewOnTime = $reviewOnTime
    nextReviewIntervalDays = $nextReviewIntervalDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRetentionRemainingDays = $minimumRetentionRemainingDays
    retentionRemainingDays = $retentionRemainingDays
    retentionRemainingMeetsPolicy = $retentionRemainingMeetsPolicy
    nextReviewWithinRetention = $nextReviewWithinRetention
    maxPreviousEvidenceAgeHours = [int]$evidence.review.maxPreviousEvidenceAgeHours
    maxReviewAgeMinutes = [int]$evidence.review.maxReviewAgeMinutes
    archiveAvailabilityStatus = [string]$evidence.controls.archiveAvailability
    evidenceInventoryStatus = [string]$evidence.controls.evidenceInventory
    objectLockStatus = [string]$evidence.controls.objectLock
    retentionPolicyStatus = [string]$evidence.controls.retentionPolicy
    encryptionStatus = [string]$evidence.controls.encryption
    accessControlStatus = [string]$evidence.controls.accessControl
    restoreVerificationStatus = [string]$evidence.controls.restoreVerification
    previousReviewGateReference = [string]$evidence.externalEvidence.previousReviewGateReference
    scheduledReviewReference = [string]$evidence.externalEvidence.scheduledReviewReference
    archiveInventoryReference = [string]$evidence.externalEvidence.archiveInventoryReference
    objectLockReference = [string]$evidence.externalEvidence.objectLockReference
    retentionPolicyReference = [string]$evidence.externalEvidence.retentionPolicyReference
    encryptionReference = [string]$evidence.externalEvidence.encryptionReference
    accessReviewReference = [string]$evidence.externalEvidence.accessReviewReference
    restoreTestReference = [string]$evidence.externalEvidence.restoreTestReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    collectedAtUtc = $collectedAt.ToString('o')
    reviewLinkDigest = $reviewLinkDigest
    baselineLinkValid = $true
    predecessorLinkValid = $true
    inheritedLineagePreserved = $true
    custodyContinuityProven = $expectedContinuityProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The recurring generation-3 custody-review integrity digest is invalid.'
}

Write-Host "Recurring generation-3 custody-review validation passed with outcome '$expectedOutcome'."
Write-Host "Review sequence $reviewSequence follows exact predecessor $previousSequence; next review is due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
