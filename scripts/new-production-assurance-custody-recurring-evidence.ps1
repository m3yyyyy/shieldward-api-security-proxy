[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousCustodyReviewEvidencePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ReviewCompletedAtUtc,
    [ValidateRange(0, 168)][int]$CompletionGraceHours = 24,

    [Parameter(Mandatory)][ValidateSet('available', 'missing', 'unknown')][string]$ArchiveAvailabilityStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$EvidenceInventoryStatus,
    [Parameter(Mandatory)][ValidateSet('enforced', 'not-enforced', 'unknown')][string]$ObjectLockStatus,
    [Parameter(Mandatory)][ValidateSet('active', 'inactive', 'unknown')][string]$RetentionPolicyStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'failed', 'unknown')][string]$EncryptionStatus,
    [Parameter(Mandatory)][ValidateSet('least-privilege', 'overbroad', 'unknown')][string]$AccessControlStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$RestoreVerificationStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousCustodyReviewGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScheduledReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArchiveInventoryReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ObjectLockReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RetentionPolicyReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EncryptionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreTestReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReviewedBy,

    [ValidateRange(1, 8760)][int]$MaxPreviousEvidenceAgeHours = 2208,
    [ValidateRange(5, 1440)][int]$MaxReviewAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-custody-recurring',
    [switch]$CheckCluster,
    [switch]$Force,
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

foreach ($reference in @(
    [pscustomobject]@{ Value = $PreviousCustodyReviewGateReference; Description = 'PreviousCustodyReviewGateReference' }
    [pscustomobject]@{ Value = $ScheduledReviewReference; Description = 'ScheduledReviewReference' }
    [pscustomobject]@{ Value = $ArchiveInventoryReference; Description = 'ArchiveInventoryReference' }
    [pscustomobject]@{ Value = $ObjectLockReference; Description = 'ObjectLockReference' }
    [pscustomobject]@{ Value = $RetentionPolicyReference; Description = 'RetentionPolicyReference' }
    [pscustomobject]@{ Value = $EncryptionReference; Description = 'EncryptionReference' }
    [pscustomobject]@{ Value = $AccessReviewReference; Description = 'AccessReviewReference' }
    [pscustomobject]@{ Value = $RestoreTestReference; Description = 'RestoreTestReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPreviousPath = Resolve-LocalStatePath -Path $PreviousCustodyReviewEvidencePath -Description 'PreviousCustodyReviewEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Previous production assurance custody review evidence is missing: $resolvedPreviousPath"
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

if (
    [string]$previous.outcome -ne 'passed' -or
    [bool]$previous.review.onTime -ne $true -or
    [bool]$previous.retention.remainingMeetsPolicy -ne $true -or
    [bool]$previous.schedule.nextReviewWithinRetention -ne $true -or
    [string]$previous.controls.archiveAvailability -ne 'available' -or
    [string]$previous.controls.evidenceInventory -ne 'complete' -or
    [string]$previous.controls.objectLock -ne 'enforced' -or
    [string]$previous.controls.retentionPolicy -ne 'active' -or
    [string]$previous.controls.encryption -ne 'verified' -or
    [string]$previous.controls.accessControl -ne 'least-privilege' -or
    [string]$previous.controls.restoreVerification -ne 'passed' -or
    [bool]$previous.decision.custodyContinuityProven -ne $true -or
    [string]$previous.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Recurring custody review requires exact passed previous custody-review evidence.'
}

$expectedDueAt = ([DateTimeOffset]$previous.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = $ReviewCompletedAtUtc.ToUniversalTime()
$previousCollectedAt = ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime()
$previousCompletedAt = ([DateTimeOffset]$previous.review.completedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$previous.retention.untilUtc).ToUniversalTime()
$previousAge = $referenceNow - $previousCollectedAt
$reviewAge = $referenceNow - $completedAt
if (
    $completedAt -lt $previousCompletedAt -or
    $previousAge.TotalHours -lt -1 -or
    $previousAge.TotalHours -gt $MaxPreviousEvidenceAgeHours -or
    $reviewAge.TotalMinutes -lt -5 -or
    $reviewAge.TotalMinutes -gt $MaxReviewAgeMinutes
) {
    throw 'Recurring custody review evidence must follow the previous review and use current freshness-bounded observations.'
}

$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddHours(-1) -and
    $completedAt -le $expectedDueAt.AddHours($CompletionGraceHours)
)
$nextReviewIntervalDays = [int]$previous.schedule.nextReviewIntervalDays
$minimumRetentionRemainingDays = [int]$previous.retention.minimumRemainingDays
$nextReviewDueAt = $completedAt.AddDays($nextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge $minimumRetentionRemainingDays
$nextReviewWithinRetention = $nextReviewDueAt -lt $retentionUntil

$hasFailure = (
    -not $reviewOnTime -or
    $ArchiveAvailabilityStatus -eq 'missing' -or
    $EvidenceInventoryStatus -eq 'incomplete' -or
    $ObjectLockStatus -eq 'not-enforced' -or
    $RetentionPolicyStatus -eq 'inactive' -or
    $EncryptionStatus -eq 'failed' -or
    $AccessControlStatus -eq 'overbroad' -or
    $RestoreVerificationStatus -eq 'failed' -or
    -not $retentionRemainingMeetsPolicy -or
    -not $nextReviewWithinRetention
)
$hasUnknown = @(
    $ArchiveAvailabilityStatus,
    $EvidenceInventoryStatus,
    $ObjectLockStatus,
    $RetentionPolicyStatus,
    $EncryptionStatus,
    $AccessControlStatus,
    $RestoreVerificationStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$custodyContinuityProven = $outcome -eq 'passed'
$nextAction = if ($ArchiveAvailabilityStatus -eq 'missing' -or $EvidenceInventoryStatus -eq 'incomplete') {
    'restore-evidence-and-investigate'
}
elseif (
    $ObjectLockStatus -eq 'not-enforced' -or
    $RetentionPolicyStatus -eq 'inactive' -or
    -not $retentionRemainingMeetsPolicy -or
    -not $nextReviewWithinRetention
) {
    'renew-retention-before-continuing'
}
elseif ($EncryptionStatus -eq 'failed' -or $AccessControlStatus -eq 'overbroad') {
    'restrict-access-and-investigate'
}
elseif ($RestoreVerificationStatus -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif (-not $reviewOnTime) {
    'escalate-missed-custody-review'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}

$collectedAt = $referenceNow
$reviewSequence = $previousSequence + 1
$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
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
    reviewSequence = $reviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceHours = $CompletionGraceHours
    reviewOnTime = $reviewOnTime
    nextReviewIntervalDays = $nextReviewIntervalDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRetentionRemainingDays = $minimumRetentionRemainingDays
    retentionRemainingDays = $retentionRemainingDays
    retentionRemainingMeetsPolicy = $retentionRemainingMeetsPolicy
    nextReviewWithinRetention = $nextReviewWithinRetention
    maxPreviousEvidenceAgeHours = $MaxPreviousEvidenceAgeHours
    maxReviewAgeMinutes = $MaxReviewAgeMinutes
    archiveAvailabilityStatus = $ArchiveAvailabilityStatus
    evidenceInventoryStatus = $EvidenceInventoryStatus
    objectLockStatus = $ObjectLockStatus
    retentionPolicyStatus = $RetentionPolicyStatus
    encryptionStatus = $EncryptionStatus
    accessControlStatus = $AccessControlStatus
    restoreVerificationStatus = $RestoreVerificationStatus
    previousCustodyReviewGateReference = $PreviousCustodyReviewGateReference
    scheduledReviewReference = $ScheduledReviewReference
    archiveInventoryReference = $ArchiveInventoryReference
    objectLockReference = $ObjectLockReference
    retentionPolicyReference = $RetentionPolicyReference
    encryptionReference = $EncryptionReference
    accessReviewReference = $AccessReviewReference
    restoreTestReference = $RestoreTestReference
    reviewedBy = $ReviewedBy
    collectedAtUtc = $collectedAt.ToString('o')
    custodyContinuityProven = $custodyContinuityProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'recurring-production-assurance-custody-review'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    candidate = [ordered]@{
        version = [string]$previous.candidate.version
        sourceTag = [string]$previous.candidate.sourceTag
        controlPlaneImage = [string]$previous.candidate.controlPlaneImage
        edgeImage = [string]$previous.candidate.edgeImage
        policyVersion = [string]$previous.candidate.policyVersion
    }
    previousCustodyReviewEvidence = [ordered]@{
        evidenceType = $previousType
        relativePath = $previousRelativePath
        sha256 = $previousHash
        integrityDigest = [string]$previous.integrityDigest
        collectedAtUtc = $previousCollectedAt.ToString('o')
        reviewSequence = $previousSequence
        outcome = [string]$previous.outcome
        custodyContinuityProven = [bool]$previous.decision.custodyContinuityProven
    }
    rootCustodyEvidence = [ordered]@{
        relativePath = [string]$rootCustody.relativePath
        sha256 = [string]$rootCustody.sha256
        integrityDigest = [string]$rootCustody.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$rootCustody.collectedAtUtc).ToUniversalTime().ToString('o')
        chainDigest = [string]$rootCustody.chainDigest
        headReviewSequence = [int]$rootCustody.headReviewSequence
        retentionUntilUtc = ([DateTimeOffset]$rootCustody.retentionUntilUtc).ToUniversalTime().ToString('o')
        outcome = [string]$rootCustody.outcome
        custodyConfirmed = [bool]$rootCustody.custodyConfirmed
    }
    review = [ordered]@{
        sequence = $reviewSequence
        previousSequence = $previousSequence
        expectedDueAtUtc = $expectedDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceHours = $CompletionGraceHours
        onTime = $reviewOnTime
        maxPreviousEvidenceAgeHours = $MaxPreviousEvidenceAgeHours
        maxReviewAgeMinutes = $MaxReviewAgeMinutes
    }
    schedule = [ordered]@{
        nextReviewIntervalDays = $nextReviewIntervalDays
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        nextReviewWithinRetention = $nextReviewWithinRetention
    }
    retention = [ordered]@{
        untilUtc = $retentionUntil.ToString('o')
        minimumRemainingDays = $minimumRetentionRemainingDays
        remainingDays = $retentionRemainingDays
        remainingMeetsPolicy = $retentionRemainingMeetsPolicy
    }
    controls = [ordered]@{
        archiveAvailability = $ArchiveAvailabilityStatus
        evidenceInventory = $EvidenceInventoryStatus
        objectLock = $ObjectLockStatus
        retentionPolicy = $RetentionPolicyStatus
        encryption = $EncryptionStatus
        accessControl = $AccessControlStatus
        restoreVerification = $RestoreVerificationStatus
    }
    externalEvidence = [ordered]@{
        previousCustodyReviewGateReference = $PreviousCustodyReviewGateReference
        scheduledReviewReference = $ScheduledReviewReference
        archiveInventoryReference = $ArchiveInventoryReference
        objectLockReference = $ObjectLockReference
        retentionPolicyReference = $RetentionPolicyReference
        encryptionReference = $EncryptionReference
        accessReviewReference = $AccessReviewReference
        restoreTestReference = $RestoreTestReference
        reviewedBy = $ReviewedBy
    }
    decision = [ordered]@{
        custodyLinkValid = $true
        custodyContinuityProven = $custodyContinuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'custody-review-{0}-sequence-{1}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $reviewSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Recurring production assurance custody review evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Recurring production assurance custody review evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review sequence $reviewSequence on time: $reviewOnTime; retention remaining: $retentionRemainingDays days"
Write-Host 'No scheduler, archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Recurring custody continuity is not proven. Preserve evidence and follow the recorded action.'
}
