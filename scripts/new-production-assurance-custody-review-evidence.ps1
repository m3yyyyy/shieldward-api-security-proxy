[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CustodyEvidencePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ScheduledReviewDueAtUtc,
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

    [ValidateRange(1, 8760)][int]$MaxCustodyEvidenceAgeHours = 2208,
    [ValidateRange(5, 1440)][int]$MaxReviewAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-custody-review',
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

$resolvedCustodyPath = Resolve-LocalStatePath -Path $CustodyEvidencePath -Description 'CustodyEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedCustodyPath -PathType Leaf)) {
    throw "Production assurance evidence custody record is missing: $resolvedCustodyPath"
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
if (
    [string]$custody.outcome -ne 'passed' -or
    [bool]$custody.chainAuditEvidence.auditPassed -ne $true -or
    [bool]$custody.archive.auditChecksumMatches -ne $true -or
    [bool]$custody.archive.chainDigestMatches -ne $true -or
    [string]$custody.archive.writeStatus -ne 'completed' -or
    [string]$custody.archive.objectLockStatus -ne 'enforced' -or
    [string]$custody.retention.policyStatus -ne 'active' -or
    [bool]$custody.retention.meetsPolicy -ne $true -or
    [string]$custody.archive.encryptionStatus -ne 'verified' -or
    [string]$custody.archive.accessControlStatus -ne 'least-privilege' -or
    [string]$custody.archive.restoreVerificationStatus -ne 'passed' -or
    [bool]$custody.decision.custodyConfirmed -ne $true -or
    [string]$custody.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Custody review requires exact passed production assurance evidence custody.'
}

$scheduledDueAt = $ScheduledReviewDueAtUtc.ToUniversalTime()
$completedAt = $ReviewCompletedAtUtc.ToUniversalTime()
$custodyCollectedAt = ([DateTimeOffset]$custody.collectedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$custody.retention.untilUtc).ToUniversalTime()
$custodyAge = $referenceNow - $custodyCollectedAt
$reviewAge = $referenceNow - $completedAt
if (
    $scheduledDueAt -lt $custodyCollectedAt -or
    $completedAt -lt $custodyCollectedAt -or
    $custodyAge.TotalHours -lt -1 -or
    $custodyAge.TotalHours -gt $MaxCustodyEvidenceAgeHours -or
    $reviewAge.TotalMinutes -lt -5 -or
    $reviewAge.TotalMinutes -gt $MaxReviewAgeMinutes
) {
    throw 'Custody review must follow the custody record and use current freshness-bounded observations.'
}

$reviewOnTime = (
    $completedAt -ge $scheduledDueAt.AddHours(-1) -and
    $completedAt -le $scheduledDueAt.AddHours($CompletionGraceHours)
)
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
    'escalate-missed-custody-review'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}

$collectedAt = $referenceNow
$custodyHash = (Get-FileHash -LiteralPath $resolvedCustodyPath -Algorithm SHA256).Hash.ToLowerInvariant()
$custodyRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedCustodyPath).Replace('\', '/')
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
    completionGraceHours = $CompletionGraceHours
    reviewOnTime = $reviewOnTime
    nextReviewIntervalDays = $NextReviewIntervalDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRetentionRemainingDays = $MinimumRetentionRemainingDays
    retentionRemainingDays = $retentionRemainingDays
    retentionRemainingMeetsPolicy = $retentionRemainingMeetsPolicy
    nextReviewWithinRetention = $nextReviewWithinRetention
    maxCustodyEvidenceAgeHours = $MaxCustodyEvidenceAgeHours
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
    custodyContinuityProven = $custodyContinuityProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'scheduled-production-assurance-custody-review'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$custody.incidentId
    closureChangeId = [string]$custody.closureChangeId
    candidate = [ordered]@{
        version = [string]$custody.candidate.version
        sourceTag = [string]$custody.candidate.sourceTag
        controlPlaneImage = [string]$custody.candidate.controlPlaneImage
        edgeImage = [string]$custody.candidate.edgeImage
        policyVersion = [string]$custody.candidate.policyVersion
    }
    custodyEvidence = [ordered]@{
        relativePath = $custodyRelativePath
        sha256 = $custodyHash
        integrityDigest = [string]$custody.integrityDigest
        collectedAtUtc = $custodyCollectedAt.ToString('o')
        chainDigest = [string]$custody.chainAuditEvidence.chainDigest
        headReviewSequence = [int]$custody.chainAuditEvidence.headReviewSequence
        retentionUntilUtc = $retentionUntil.ToString('o')
        outcome = [string]$custody.outcome
        custodyConfirmed = [bool]$custody.decision.custodyConfirmed
    }
    review = [ordered]@{
        scheduledDueAtUtc = $scheduledDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceHours = $CompletionGraceHours
        onTime = $reviewOnTime
        maxCustodyEvidenceAgeHours = $MaxCustodyEvidenceAgeHours
        maxReviewAgeMinutes = $MaxReviewAgeMinutes
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
        custodyLinkValid = $true
        custodyContinuityProven = $custodyContinuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'custody-review-{0}-sequence-{1}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), [int]$custody.chainAuditEvidence.headReviewSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance custody review evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production assurance custody review evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review on time: $reviewOnTime; retention remaining: $retentionRemainingDays days; next review within retention: $nextReviewWithinRetention"
Write-Host 'No archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Custody continuity is not proven. Preserve evidence and follow the recorded action.'
}
