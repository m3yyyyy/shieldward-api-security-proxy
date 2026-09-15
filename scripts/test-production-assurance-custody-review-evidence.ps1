[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$CustodyEvidencePath = '',
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
    throw "Production assurance custody review evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'scheduled-production-assurance-custody-review'
) {
    throw 'The supplied production assurance custody review evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The custody review targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The custody review uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedCustodyPath = if ([string]::IsNullOrWhiteSpace($CustodyEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.custodyEvidence.relativePath) -Description 'Recorded custody evidence path'
}
else {
    Resolve-LocalStatePath -Path $CustodyEvidencePath -Description 'CustodyEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedCustodyPath -PathType Leaf)) {
    throw "Recorded production assurance evidence custody is missing: $resolvedCustodyPath"
}
$custodyValidationArguments = @{
    EvidencePath = $resolvedCustodyPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $custodyValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-evidence.ps1') @custodyValidationArguments 6>$null

$custody = Get-Content -Raw -LiteralPath $resolvedCustodyPath | ConvertFrom-Json
$custodyRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedCustodyPath).Replace('\', '/')
$custodyHash = (Get-FileHash -LiteralPath $resolvedCustodyPath -Algorithm SHA256).Hash.ToLowerInvariant()
$custodyCollectedAt = ([DateTimeOffset]$custody.collectedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$custody.retention.untilUtc).ToUniversalTime()
if (
    $custodyRelativePath -ne [string]$evidence.custodyEvidence.relativePath -or
    $custodyHash -ne [string]$evidence.custodyEvidence.sha256 -or
    [string]$custody.integrityDigest -ne [string]$evidence.custodyEvidence.integrityDigest -or
    $custodyCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.custodyEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$custody.chainAuditEvidence.chainDigest -ne [string]$evidence.custodyEvidence.chainDigest -or
    [int]$custody.chainAuditEvidence.headReviewSequence -ne [int]$evidence.custodyEvidence.headReviewSequence -or
    $retentionUntil.ToString('o') -ne ([DateTimeOffset]$evidence.custodyEvidence.retentionUntilUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.custodyEvidence.outcome -ne 'passed' -or
    [bool]$evidence.custodyEvidence.custodyConfirmed -ne $true
) {
    throw 'The exact passed production assurance evidence custody no longer matches the custody review.'
}
if (
    [string]$custody.outcome -ne 'passed' -or
    [bool]$custody.decision.custodyConfirmed -ne $true -or
    [string]$custody.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Custody review requires passed production assurance evidence custody.'
}
if (
    [string]$evidence.incidentId -ne [string]$custody.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$custody.closureChangeId -or
    [string]$evidence.candidate.version -ne [string]$custody.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$custody.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$custody.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$custody.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$custody.candidate.policyVersion
) {
    throw 'The custody review identity or candidate does not match its custody evidence.'
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
        throw "The custody review contains unsupported $($status.Name) status '$($status.Actual)'."
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
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

try {
    $scheduledDueAt = ([DateTimeOffset]$evidence.review.scheduledDueAtUtc).ToUniversalTime()
    $completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
    $collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
    $nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
    $recordedRetentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
}
catch {
    throw 'The production assurance custody review contains an invalid timestamp.'
}
$reviewOnTime = (
    $completedAt -ge $scheduledDueAt.AddHours(-1) -and
    $completedAt -le $scheduledDueAt.AddHours([int]$evidence.review.completionGraceHours)
)
$expectedNextReviewDueAt = $completedAt.AddDays([int]$evidence.schedule.nextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge [int]$evidence.retention.minimumRemainingDays
$nextReviewWithinRetention = $nextReviewDueAt -lt $retentionUntil
$custodyAgeAtCollection = $collectedAt - $custodyCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    $scheduledDueAt -lt $custodyCollectedAt -or
    $completedAt -lt $custodyCollectedAt -or
    $recordedRetentionUntil.ToString('o') -ne $retentionUntil.ToString('o') -or
    [int]$evidence.review.completionGraceHours -lt 0 -or
    [int]$evidence.review.completionGraceHours -gt 168 -or
    [int]$evidence.schedule.nextReviewIntervalDays -lt 1 -or
    [int]$evidence.schedule.nextReviewIntervalDays -gt 3650 -or
    $nextReviewDueAt.ToString('o') -ne $expectedNextReviewDueAt.ToString('o') -or
    [int]$evidence.retention.minimumRemainingDays -lt 1 -or
    [int]$evidence.retention.minimumRemainingDays -gt 3650 -or
    [double]$evidence.retention.remainingDays -ne $retentionRemainingDays -or
    [int]$evidence.review.maxCustodyEvidenceAgeHours -lt 1 -or
    [int]$evidence.review.maxCustodyEvidenceAgeHours -gt 8760 -or
    $custodyAgeAtCollection.TotalHours -lt -1 -or
    $custodyAgeAtCollection.TotalHours -gt [int]$evidence.review.maxCustodyEvidenceAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The production assurance custody review timing, retention, or freshness boundary is invalid.'
}
if (
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $retentionRemainingMeetsPolicy -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $nextReviewWithinRetention
) {
    throw 'The custody review schedule or retention decision is inconsistent with recorded evidence.'
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
    throw 'The production assurance custody review outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    custodyEvidenceSha256 = $custodyHash
    custodyEvidenceIntegrityDigest = [string]$custody.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$custody.incidentId
    closureChangeId = [string]$custody.closureChangeId
    releaseVersion = [string]$custody.candidate.version
    sourceTag = [string]$custody.candidate.sourceTag
    controlPlaneImage = [string]$custody.candidate.controlPlaneImage
    edgeImage = [string]$custody.candidate.edgeImage
    policyVersion = [string]$custody.candidate.policyVersion
    chainDigest = [string]$custody.chainAuditEvidence.chainDigest
    headReviewSequence = [int]$custody.chainAuditEvidence.headReviewSequence
    custodyCollectedAtUtc = $custodyCollectedAt.ToString('o')
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
    maxCustodyEvidenceAgeHours = [int]$evidence.review.maxCustodyEvidenceAgeHours
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
    custodyContinuityProven = $expectedContinuityProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance custody review integrity digest is invalid.'
}

Write-Host "Production assurance custody review validation passed with outcome '$expectedOutcome'."
Write-Host "Review on time: $reviewOnTime; retention remaining meets policy: $retentionRemainingMeetsPolicy; next review within retention: $nextReviewWithinRetention"
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
