[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
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
    throw "Generation-5 custody-review evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'generation-5-production-assurance-custody-review'
) {
    throw 'The supplied generation-5 custody-review evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext -or [string]$evidence.namespace -ne 'shieldward') {
    throw 'The generation-5 custody-review evidence targets the wrong context or namespace.'
}

$resolvedBaselinePath = if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.generation5CustodyBaseline.relativePath) -Description 'Recorded baseline path'
}
else {
    Resolve-LocalStatePath -Path $BaselinePath -Description 'BaselinePath'
}
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Recorded generation-5 custody baseline is missing: $resolvedBaselinePath"
}
$baselineValidationArguments = @{
    BaselinePath = $resolvedBaselinePath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    $baselineValidationArguments.RenewalEvidencePath = $RenewalEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $baselineValidationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $baselineValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline.ps1') @baselineValidationArguments 6>$null

$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json
$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/')
$baselineCollectedAt = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime()
if (
    $baselineRelativePath -ne [string]$evidence.generation5CustodyBaseline.relativePath -or
    $baselineHash -ne [string]$evidence.generation5CustodyBaseline.sha256 -or
    [string]$baseline.integrityDigest -ne [string]$evidence.generation5CustodyBaseline.integrityDigest -or
    [string]$baseline.generation5Baseline.lineageDigest -ne [string]$evidence.generation5CustodyBaseline.lineageDigest -or
    $baselineCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.generation5CustodyBaseline.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$evidence.generation5CustodyBaseline.generation -ne 5 -or
    [int]$evidence.generation5CustodyBaseline.renewalSequence -ne 4 -or
    [string]$evidence.generation5CustodyBaseline.outcome -ne 'passed' -or
    [bool]$evidence.generation5CustodyBaseline.baselineEstablished -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-generation-5-custody-review'
) {
    throw 'The exact passed generation-5 custody baseline no longer matches the sequence-13 review evidence.'
}
if (
    [string]$evidence.changeId -ne [string]$baseline.changeId -or
    [string]$evidence.incidentId -ne [string]$baseline.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$baseline.closureChangeId -or
    -not (Test-JsonEqual -Left $evidence.candidate -Right $baseline.candidate) -or
    -not (Test-JsonEqual -Left $evidence.inheritedLineage -Right $baseline.inheritedLineage) -or
    [string]$evidence.renewalEvidence.sha256 -ne [string]$baseline.renewalEvidence.sha256 -or
    [string]$evidence.renewalEvidence.integrityDigest -ne [string]$baseline.renewalEvidence.integrityDigest
) {
    throw 'The sequence-13 custody review changed the production identity or inherited lineage.'
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
        throw "The sequence-13 custody review contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
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

$baselineEstablishedAt = ([DateTimeOffset]$baseline.generation5Baseline.establishedAtUtc).ToUniversalTime()
$scheduledDueAt = ([DateTimeOffset]$baseline.generation5Baseline.nextReviewDueAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$baseline.generation5Baseline.renewedRetentionUntilUtc).ToUniversalTime()
$completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$reviewSequence = [int]$baseline.generation5Baseline.nextReviewSequence
$previousHeadSequence = [int]$baseline.generation5Baseline.previousHeadReviewSequence
$reviewOnTime = (
    $completedAt -ge $scheduledDueAt.AddHours(-1) -and
    $completedAt -le $scheduledDueAt.AddHours([int]$evidence.review.completionGraceHours)
)
$nextReviewDueAt = $completedAt.AddDays([int]$evidence.schedule.nextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge [int]$evidence.retention.minimumRemainingDays
$nextReviewWithinRetention = $nextReviewDueAt -lt $retentionUntil
$baselineAgeAtReview = $completedAt - $baselineCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    $reviewSequence -ne ($previousHeadSequence + 1) -or
    [int]$evidence.review.sequence -ne $reviewSequence -or
    [int]$evidence.review.previousHeadSequence -ne $previousHeadSequence -or
    ([DateTimeOffset]$evidence.review.scheduledDueAtUtc).ToUniversalTime().ToString('o') -ne $scheduledDueAt.ToString('o') -or
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    $completedAt -lt $baselineEstablishedAt -or
    [int]$evidence.review.maxBaselineAgeHours -lt 1 -or
    [int]$evidence.review.maxBaselineAgeHours -gt 8760 -or
    $baselineAgeAtReview.TotalHours -lt -1 -or
    $baselineAgeAtReview.TotalHours -gt [int]$evidence.review.maxBaselineAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5) -or
    ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $nextReviewWithinRetention -or
    ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime().ToString('o') -ne $retentionUntil.ToString('o') -or
    [double]$evidence.retention.remainingDays -ne $retentionRemainingDays -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $retentionRemainingMeetsPolicy
) {
    throw 'The sequence-13 custody review timing, sequence, schedule, or retention calculation is invalid.'
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
elseif ([string]$evidence.controls.encryption -eq 'failed' -or [string]$evidence.controls.accessControl -eq 'overbroad') {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.controls.restoreVerification -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif (-not $reviewOnTime) {
    'escalate-missed-generation-5-custody-review'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-generation-5-custody-reviews'
}

$reviewLink = [ordered]@{
    generation5BaselineSha256 = $baselineHash
    generation5BaselineIntegrityDigest = [string]$baseline.integrityDigest
    generation5LineageDigest = [string]$baseline.generation5Baseline.lineageDigest
    previousReviewChainDigest = [string]$baseline.inheritedLineage.generation4ReviewChainDigest
    previousHeadReviewSequence = $previousHeadSequence
    reviewSequence = $reviewSequence
    scheduledReviewDueAtUtc = $scheduledDueAt.ToString('o')
    reviewCompletedAtUtc = $completedAt.ToString('o')
}
$reviewLinkDigest = Get-Sha256Text -Text ($reviewLink | ConvertTo-Json -Depth 4 -Compress)
if (
    [string]$evidence.review.linkDigest -ne $reviewLinkDigest -or
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.baselineLinkValid -ne $true -or
    [bool]$evidence.decision.inheritedLineagePreserved -ne $true -or
    [bool]$evidence.decision.custodyContinuityProven -ne $expectedContinuityProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The sequence-13 custody review linkage, outcome, or action is inconsistent.'
}

$integrity = [ordered]@{
    generation5BaselineSha256 = $baselineHash
    generation5BaselineIntegrityDigest = [string]$baseline.integrityDigest
    generation5LineageDigest = [string]$baseline.generation5Baseline.lineageDigest
    renewalEvidenceSha256 = [string]$baseline.renewalEvidence.sha256
    renewalEvidenceIntegrityDigest = [string]$baseline.renewalEvidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$baseline.changeId
    incidentId = [string]$baseline.incidentId
    closureChangeId = [string]$baseline.closureChangeId
    releaseVersion = [string]$baseline.candidate.version
    sourceTag = [string]$baseline.candidate.sourceTag
    controlPlaneImage = [string]$baseline.candidate.controlPlaneImage
    edgeImage = [string]$baseline.candidate.edgeImage
    policyVersion = [string]$baseline.candidate.policyVersion
    previousBaselineSha256 = [string]$baseline.inheritedLineage.generation4BaselineSha256
    previousBaselineIntegrityDigest = [string]$baseline.inheritedLineage.generation4BaselineIntegrityDigest
    previousLineageDigest = [string]$baseline.inheritedLineage.generation4LineageDigest
    previousRenewalEvidenceSha256 = [string]$baseline.inheritedLineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$baseline.inheritedLineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineageDigest = Get-Sha256Text -Text ($baseline.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress)
    previousReviewChainDigest = [string]$baseline.inheritedLineage.generation4ReviewChainDigest
    baselineGeneration = [int]$baseline.generation5Baseline.generation
    renewalSequence = [int]$baseline.generation5Baseline.renewalSequence
    previousHeadReviewSequence = $previousHeadSequence
    reviewSequence = $reviewSequence
    baselineCollectedAtUtc = $baselineCollectedAt.ToString('o')
    retentionUntilUtc = $retentionUntil.ToString('o')
    scheduledReviewDueAtUtc = $scheduledDueAt.ToString('o')
    reviewCompletedAtUtc = $completedAt.ToString('o')
    completionGraceHours = [int]$evidence.review.completionGraceHours
    reviewOnTime = $reviewOnTime
    nextReviewIntervalDays = [int]$evidence.schedule.nextReviewIntervalDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRetentionRemainingDays = [int]$evidence.retention.minimumRemainingDays
    retentionRemainingDays = $retentionRemainingDays
    retentionRemainingMeetsPolicy = $retentionRemainingMeetsPolicy
    nextReviewWithinRetention = $nextReviewWithinRetention
    maxBaselineAgeHours = [int]$evidence.review.maxBaselineAgeHours
    maxReviewAgeMinutes = [int]$evidence.review.maxReviewAgeMinutes
    archiveAvailabilityStatus = [string]$evidence.controls.archiveAvailability
    evidenceInventoryStatus = [string]$evidence.controls.evidenceInventory
    objectLockStatus = [string]$evidence.controls.objectLock
    retentionPolicyStatus = [string]$evidence.controls.retentionPolicy
    encryptionStatus = [string]$evidence.controls.encryption
    accessControlStatus = [string]$evidence.controls.accessControl
    restoreVerificationStatus = [string]$evidence.controls.restoreVerification
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
    inheritedLineagePreserved = $true
    custodyContinuityProven = $expectedContinuityProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 12 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The generation-5 custody-review evidence integrity digest is invalid.'
}

Write-Host "Generation-5 custody-review validation passed with outcome '$expectedOutcome'."
Write-Host "Generation 5 review sequence $reviewSequence preserved inherited lineage; next review is due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
