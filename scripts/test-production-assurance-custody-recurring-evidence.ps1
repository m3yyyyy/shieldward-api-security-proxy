[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PreviousCustodyReviewEvidencePath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [switch]$CheckCluster,
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

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description must not be empty."
    }
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

function Assert-EvidenceReference {
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
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($sha256.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
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
    throw "Recurring production assurance custody review evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'recurring-production-assurance-custody-review'
) {
    throw 'The supplied recurring production assurance custody review evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The recurring custody review targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The recurring custody review uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPreviousPath = if ([string]::IsNullOrWhiteSpace($PreviousCustodyReviewEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.previousCustodyReviewEvidence.relativePath) -Description 'Recorded previous custody review evidence path'
}
else {
    Resolve-LocalStatePath -Path $PreviousCustodyReviewEvidencePath -Description 'PreviousCustodyReviewEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Recorded previous production assurance custody review evidence is missing: $resolvedPreviousPath"
}
$previous = Get-Content -Raw -LiteralPath $resolvedPreviousPath | ConvertFrom-Json
$previousType = [string]$previous.evidenceType
$previousValidationArguments = @{
    EvidencePath = $resolvedPreviousPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $previousValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
if ($previousType -eq 'scheduled-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-custody-review-evidence.ps1') @previousValidationArguments 6>$null
    $previousSequence = 1
    $rootCustody = $previous.custodyEvidence
}
elseif ($previousType -eq 'recurring-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-evidence.ps1') @previousValidationArguments 6>$null
    $previousSequence = [int]$previous.review.sequence
    $rootCustody = $previous.rootCustodyEvidence
}
else {
    throw "Previous custody review evidence type '$previousType' is unsupported."
}

$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previousCollectedAt = ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime()
if (
    $previousType -ne [string]$evidence.previousCustodyReviewEvidence.evidenceType -or
    $previousRelativePath -ne [string]$evidence.previousCustodyReviewEvidence.relativePath -or
    $previousHash -ne [string]$evidence.previousCustodyReviewEvidence.sha256 -or
    [string]$previous.integrityDigest -ne [string]$evidence.previousCustodyReviewEvidence.integrityDigest -or
    $previousCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.previousCustodyReviewEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    $previousSequence -ne [int]$evidence.previousCustodyReviewEvidence.reviewSequence -or
    [string]$evidence.previousCustodyReviewEvidence.outcome -ne 'passed' -or
    [bool]$evidence.previousCustodyReviewEvidence.custodyContinuityProven -ne $true
) {
    throw 'The exact passed previous production assurance custody review no longer matches recurring evidence.'
}
if (
    [string]$previous.outcome -ne 'passed' -or
    [bool]$previous.decision.custodyContinuityProven -ne $true -or
    [string]$previous.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Recurring custody review requires passed previous custody-review evidence.'
}

if (
    [string]$rootCustody.relativePath -ne [string]$evidence.rootCustodyEvidence.relativePath -or
    [string]$rootCustody.sha256 -ne [string]$evidence.rootCustodyEvidence.sha256 -or
    [string]$rootCustody.integrityDigest -ne [string]$evidence.rootCustodyEvidence.integrityDigest -or
    ([DateTimeOffset]$rootCustody.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.rootCustodyEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$rootCustody.chainDigest -ne [string]$evidence.rootCustodyEvidence.chainDigest -or
    [int]$rootCustody.headReviewSequence -ne [int]$evidence.rootCustodyEvidence.headReviewSequence -or
    ([DateTimeOffset]$rootCustody.retentionUntilUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.rootCustodyEvidence.retentionUntilUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.rootCustodyEvidence.outcome -ne 'passed' -or
    [bool]$evidence.rootCustodyEvidence.custodyConfirmed -ne $true
) {
    throw 'The root production assurance custody boundary changed in the recurring review chain.'
}
if (
    [string]$evidence.incidentId -ne [string]$previous.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$previous.closureChangeId -or
    [string]$evidence.candidate.version -ne [string]$previous.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$previous.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$previous.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$previous.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$previous.candidate.policyVersion
) {
    throw 'The recurring custody review identity or candidate does not match its predecessor.'
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
        throw "The recurring custody review contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.previousCustodyReviewGateReference; Description = 'Previous custody review gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.scheduledReviewReference; Description = 'Scheduled review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.archiveInventoryReference; Description = 'Archive inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.objectLockReference; Description = 'Object lock reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.retentionPolicyReference; Description = 'Retention policy reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.encryptionReference; Description = 'Encryption reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessReviewReference; Description = 'Access review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreTestReference; Description = 'Restore test reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'Reviewed by' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

try {
    $expectedDueAt = ([DateTimeOffset]$previous.schedule.nextReviewDueAtUtc).ToUniversalTime()
    $completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
    $collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
    $nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
    $retentionUntil = ([DateTimeOffset]$previous.retention.untilUtc).ToUniversalTime()
    $recordedRetentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
}
catch {
    throw 'The recurring production assurance custody review contains an invalid timestamp.'
}
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddHours(-1) -and
    $completedAt -le $expectedDueAt.AddHours([int]$evidence.review.completionGraceHours)
)
$nextReviewIntervalDays = [int]$previous.schedule.nextReviewIntervalDays
$minimumRetentionRemainingDays = [int]$previous.retention.minimumRemainingDays
$expectedNextReviewDueAt = $completedAt.AddDays($nextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge $minimumRetentionRemainingDays
$nextReviewWithinRetention = $nextReviewDueAt -lt $retentionUntil
$previousAgeAtCollection = $collectedAt - $previousCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    [int]$evidence.review.sequence -ne ($previousSequence + 1) -or
    [int]$evidence.review.previousSequence -ne $previousSequence -or
    ([DateTimeOffset]$evidence.review.expectedDueAtUtc).ToUniversalTime().ToString('o') -ne $expectedDueAt.ToString('o') -or
    $completedAt -lt ([DateTimeOffset]$previous.review.completedAtUtc).ToUniversalTime() -or
    $recordedRetentionUntil.ToString('o') -ne $retentionUntil.ToString('o') -or
    [int]$evidence.review.completionGraceHours -lt 0 -or
    [int]$evidence.review.completionGraceHours -gt 168 -or
    [int]$evidence.schedule.nextReviewIntervalDays -ne $nextReviewIntervalDays -or
    $nextReviewDueAt.ToString('o') -ne $expectedNextReviewDueAt.ToString('o') -or
    [int]$evidence.retention.minimumRemainingDays -ne $minimumRetentionRemainingDays -or
    [double]$evidence.retention.remainingDays -ne $retentionRemainingDays -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -lt 1 -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -gt 8760 -or
    $previousAgeAtCollection.TotalHours -lt -1 -or
    $previousAgeAtCollection.TotalHours -gt [int]$evidence.review.maxPreviousEvidenceAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The recurring custody review sequence, timing, retention, or freshness boundary is invalid.'
}
if (
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $retentionRemainingMeetsPolicy -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $nextReviewWithinRetention
) {
    throw 'The recurring custody review schedule or retention decision is inconsistent with recorded evidence.'
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
$expectedNextAction = if (
    [string]$evidence.controls.archiveAvailability -eq 'missing' -or
    [string]$evidence.controls.evidenceInventory -eq 'incomplete'
) {
    'restore-evidence-and-investigate'
}
elseif (
    [string]$evidence.controls.objectLock -eq 'not-enforced' -or
    [string]$evidence.controls.retentionPolicy -eq 'inactive' -or
    -not $retentionRemainingMeetsPolicy -or
    -not $nextReviewWithinRetention
) {
    'renew-retention-before-continuing'
}
elseif (
    [string]$evidence.controls.encryption -eq 'failed' -or
    [string]$evidence.controls.accessControl -eq 'overbroad'
) {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.controls.restoreVerification -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif (-not $reviewOnTime) {
    'escalate-missed-custody-review'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.custodyLinkValid -ne $true -or
    [bool]$evidence.decision.custodyContinuityProven -ne $expectedContinuityProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The recurring production assurance custody review outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    previousCustodyReviewEvidenceType = $previousType
    previousCustodyReviewEvidenceSha256 = $previousHash
    previousCustodyReviewIntegrityDigest = [string]$previous.integrityDigest
    previousReviewSequence = $previousSequence
    rootCustodyEvidenceSha256 = [string]$rootCustody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$rootCustody.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    releaseVersion = [string]$previous.candidate.version
    sourceTag = [string]$previous.candidate.sourceTag
    controlPlaneImage = [string]$previous.candidate.controlPlaneImage
    edgeImage = [string]$previous.candidate.edgeImage
    policyVersion = [string]$previous.candidate.policyVersion
    chainDigest = [string]$rootCustody.chainDigest
    headReviewSequence = [int]$rootCustody.headReviewSequence
    previousCollectedAtUtc = $previousCollectedAt.ToString('o')
    retentionUntilUtc = $retentionUntil.ToString('o')
    reviewSequence = [int]$evidence.review.sequence
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
    previousCustodyReviewGateReference = [string]$evidence.externalEvidence.previousCustodyReviewGateReference
    scheduledReviewReference = [string]$evidence.externalEvidence.scheduledReviewReference
    archiveInventoryReference = [string]$evidence.externalEvidence.archiveInventoryReference
    objectLockReference = [string]$evidence.externalEvidence.objectLockReference
    retentionPolicyReference = [string]$evidence.externalEvidence.retentionPolicyReference
    encryptionReference = [string]$evidence.externalEvidence.encryptionReference
    accessReviewReference = [string]$evidence.externalEvidence.accessReviewReference
    restoreTestReference = [string]$evidence.externalEvidence.restoreTestReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    collectedAtUtc = $collectedAt.ToString('o')
    custodyContinuityProven = $expectedContinuityProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The recurring production assurance custody review integrity digest is invalid.'
}

Write-Host "Recurring production assurance custody review validation passed with outcome '$expectedOutcome'."
Write-Host "Review sequence $($evidence.review.sequence) on time: $reviewOnTime; next review within retention: $nextReviewWithinRetention"
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
