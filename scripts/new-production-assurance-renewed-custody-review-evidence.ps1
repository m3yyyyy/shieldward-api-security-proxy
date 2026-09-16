[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BaselinePath,
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ReviewCompletedAtUtc,
    [ValidateRange(0, 168)][int]$CompletionGraceHours = 24,
    [ValidateRange(1, 3650)][int]$NextReviewIntervalDays = 90,
    [ValidateRange(1, 3650)][int]$MinimumRetentionRemainingDays = 90,

    [Parameter(Mandatory)][ValidateSet('available', 'missing', 'unknown')][string]$ArchiveAvailabilityStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$EvidenceInventoryStatus,
    [Parameter(Mandatory)][ValidateSet('enforced', 'not-enforced', 'unknown')][string]$ObjectLockStatus,
    [Parameter(Mandatory)][ValidateSet('active', 'inactive', 'unknown')][string]$RetentionPolicyStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'failed', 'unknown')][string]$EncryptionStatus,
    [Parameter(Mandatory)][ValidateSet('least-privilege', 'overbroad', 'unknown')][string]$AccessControlStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$RestoreVerificationStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScheduledReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArchiveInventoryReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ObjectLockReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RetentionPolicyReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EncryptionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreTestReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReviewedBy,

    [ValidateRange(1, 8760)][int]$MaxBaselineAgeHours = 2208,
    [ValidateRange(5, 1440)][int]$MaxReviewAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-renewed-custody-review',
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
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($sha256.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

foreach ($reference in @(
    [pscustomobject]@{ Value = $ScheduledReviewReference; Description = 'ScheduledReviewReference' }
    [pscustomobject]@{ Value = $ArchiveInventoryReference; Description = 'ArchiveInventoryReference' }
    [pscustomobject]@{ Value = $ObjectLockReference; Description = 'ObjectLockReference' }
    [pscustomobject]@{ Value = $RetentionPolicyReference; Description = 'RetentionPolicyReference' }
    [pscustomobject]@{ Value = $EncryptionReference; Description = 'EncryptionReference' }
    [pscustomobject]@{ Value = $AccessReviewReference; Description = 'AccessReviewReference' }
    [pscustomobject]@{ Value = $RestoreTestReference; Description = 'RestoreTestReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedBaselinePath = Resolve-LocalStatePath -Path $BaselinePath -Description 'BaselinePath'
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Passed production assurance renewed custody-review baseline is missing: $resolvedBaselinePath"
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
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @baselineValidationArguments 6>$null

$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json
if (
    [string]$baseline.outcome -ne 'passed' -or
    [bool]$baseline.decision.renewalEvidenceVerified -ne $true -or
    [bool]$baseline.decision.originalCustodyPreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [bool]$baseline.decision.baselineEstablished -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-scheduled-custody-reviews'
) {
    throw 'Renewed custody review requires an exact passed Chapter 61 baseline.'
}

$baselineCollectedAt = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime()
$baselineEstablishedAt = ([DateTimeOffset]$baseline.renewedBaseline.establishedAtUtc).ToUniversalTime()
$scheduledDueAt = ([DateTimeOffset]$baseline.renewedBaseline.nextReviewDueAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$baseline.renewedBaseline.renewedRetentionUntilUtc).ToUniversalTime()
$completedAt = $ReviewCompletedAtUtc.ToUniversalTime()
$baselineAge = $referenceNow - $baselineCollectedAt
$reviewAge = $referenceNow - $completedAt
if (
    $completedAt -lt $baselineEstablishedAt -or
    $baselineAge.TotalHours -lt -1 -or
    $baselineAge.TotalHours -gt $MaxBaselineAgeHours -or
    $reviewAge.TotalMinutes -lt -5 -or
    $reviewAge.TotalMinutes -gt $MaxReviewAgeMinutes
) {
    throw 'Renewed custody review must follow the baseline and use current freshness-bounded observations.'
}

$reviewOnTime = (
    $completedAt -ge $scheduledDueAt.AddHours(-1) -and
    $completedAt -le $scheduledDueAt.AddHours($CompletionGraceHours)
)
$reviewSequence = [int]$baseline.renewedBaseline.nextReviewSequence
$previousHeadSequence = [int]$baseline.renewedBaseline.previousHeadReviewSequence
$nextReviewDueAt = $completedAt.AddDays($NextReviewIntervalDays)
$retentionRemainingDays = [math]::Round(($retentionUntil - $completedAt).TotalDays, 6)
$retentionRemainingMeetsPolicy = $retentionRemainingDays -ge $MinimumRetentionRemainingDays
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
    'escalate-missed-renewed-custody-review'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-renewed-custody-reviews'
}

$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/')
$reviewLink = [ordered]@{
    renewedBaselineSha256 = $baselineHash
    renewedBaselineIntegrityDigest = [string]$baseline.integrityDigest
    renewedLineageDigest = [string]$baseline.renewedBaseline.lineageDigest
    priorReviewChainDigest = [string]$baseline.priorReviewChain.digest
    previousHeadReviewSequence = $previousHeadSequence
    reviewSequence = $reviewSequence
    scheduledReviewDueAtUtc = $scheduledDueAt.ToString('o')
    reviewCompletedAtUtc = $completedAt.ToString('o')
}
$reviewLinkDigest = Get-Sha256Text -Text ($reviewLink | ConvertTo-Json -Depth 4 -Compress)

$collectedAt = $referenceNow
$integrity = [ordered]@{
    renewedBaselineSha256 = $baselineHash
    renewedBaselineIntegrityDigest = [string]$baseline.integrityDigest
    renewedLineageDigest = [string]$baseline.renewedBaseline.lineageDigest
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
    rootCustodyEvidenceSha256 = [string]$baseline.originalCustody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$baseline.originalCustody.integrityDigest
    rootCustodyChainDigest = [string]$baseline.originalCustody.chainDigest
    priorReviewChainDigest = [string]$baseline.priorReviewChain.digest
    baselineGeneration = [int]$baseline.renewedBaseline.generation
    renewalSequence = [int]$baseline.renewedBaseline.renewalSequence
    previousHeadReviewSequence = $previousHeadSequence
    reviewSequence = $reviewSequence
    baselineCollectedAtUtc = $baselineCollectedAt.ToString('o')
    retentionUntilUtc = $retentionUntil.ToString('o')
    scheduledReviewDueAtUtc = $scheduledDueAt.ToString('o')
    reviewCompletedAtUtc = $completedAt.ToString('o')
    completionGraceHours = $CompletionGraceHours
    reviewOnTime = $reviewOnTime
    nextReviewIntervalDays = $NextReviewIntervalDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRetentionRemainingDays = $MinimumRetentionRemainingDays
    retentionRemainingDays = $retentionRemainingDays
    retentionRemainingMeetsPolicy = $retentionRemainingMeetsPolicy
    nextReviewWithinRetention = $nextReviewWithinRetention
    maxBaselineAgeHours = $MaxBaselineAgeHours
    maxReviewAgeMinutes = $MaxReviewAgeMinutes
    archiveAvailabilityStatus = $ArchiveAvailabilityStatus
    evidenceInventoryStatus = $EvidenceInventoryStatus
    objectLockStatus = $ObjectLockStatus
    retentionPolicyStatus = $RetentionPolicyStatus
    encryptionStatus = $EncryptionStatus
    accessControlStatus = $AccessControlStatus
    restoreVerificationStatus = $RestoreVerificationStatus
    scheduledReviewReference = $ScheduledReviewReference
    archiveInventoryReference = $ArchiveInventoryReference
    objectLockReference = $ObjectLockReference
    retentionPolicyReference = $RetentionPolicyReference
    encryptionReference = $EncryptionReference
    accessReviewReference = $AccessReviewReference
    restoreTestReference = $RestoreTestReference
    reviewedBy = $ReviewedBy
    collectedAtUtc = $collectedAt.ToString('o')
    reviewLinkDigest = $reviewLinkDigest
    baselineLinkValid = $true
    originalLineagePreserved = $true
    custodyContinuityProven = $custodyContinuityProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'renewed-production-assurance-custody-review'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$baseline.changeId
    incidentId = [string]$baseline.incidentId
    closureChangeId = [string]$baseline.closureChangeId
    candidate = $baseline.candidate
    renewedCustodyBaseline = [ordered]@{
        relativePath = $baselineRelativePath
        sha256 = $baselineHash
        integrityDigest = [string]$baseline.integrityDigest
        lineageDigest = [string]$baseline.renewedBaseline.lineageDigest
        collectedAtUtc = $baselineCollectedAt.ToString('o')
        generation = [int]$baseline.renewedBaseline.generation
        renewalSequence = [int]$baseline.renewedBaseline.renewalSequence
        outcome = [string]$baseline.outcome
        baselineEstablished = [bool]$baseline.decision.baselineEstablished
    }
    renewalEvidence = [ordered]@{
        sha256 = [string]$baseline.renewalEvidence.sha256
        integrityDigest = [string]$baseline.renewalEvidence.integrityDigest
    }
    originalCustody = $baseline.originalCustody
    priorReviewChain = $baseline.priorReviewChain
    review = [ordered]@{
        sequence = $reviewSequence
        previousHeadSequence = $previousHeadSequence
        scheduledDueAtUtc = $scheduledDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceHours = $CompletionGraceHours
        onTime = $reviewOnTime
        maxBaselineAgeHours = $MaxBaselineAgeHours
        maxReviewAgeMinutes = $MaxReviewAgeMinutes
        linkDigest = $reviewLinkDigest
    }
    schedule = [ordered]@{
        nextReviewIntervalDays = $NextReviewIntervalDays
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        nextReviewWithinRetention = $nextReviewWithinRetention
    }
    retention = [ordered]@{
        untilUtc = $retentionUntil.ToString('o')
        minimumRemainingDays = $MinimumRetentionRemainingDays
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
        baselineLinkValid = $true
        originalLineagePreserved = $true
        custodyContinuityProven = $custodyContinuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'renewed-custody-review-{0}-sequence-{1}.json' -f $collectedAt.ToString('yyyyMMddTHHmmssZ'), $reviewSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance renewed custody-review evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production assurance renewed custody-review evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review sequence $reviewSequence on time: $reviewOnTime; retention remaining: $retentionRemainingDays days."
Write-Host 'No review was scheduled and no archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Renewed custody continuity is not proven. Preserve evidence and follow the recorded action.'
}
