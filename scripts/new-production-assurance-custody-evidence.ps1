[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainAuditEvidencePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ArchivedAtUtc,
    [Parameter(Mandatory)][DateTimeOffset]$RetentionUntilUtc,
    [Parameter(Mandatory)][ValidateRange(30, 3650)][int]$RequiredRetentionDays,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ArchivedAuditSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ArchivedChainDigest,

    [Parameter(Mandatory)][ValidateSet('completed', 'failed', 'unknown')][string]$ArchiveWriteStatus,
    [Parameter(Mandatory)][ValidateSet('enforced', 'not-enforced', 'unknown')][string]$ObjectLockStatus,
    [Parameter(Mandatory)][ValidateSet('active', 'inactive', 'unknown')][string]$RetentionPolicyStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'failed', 'unknown')][string]$EncryptionStatus,
    [Parameter(Mandatory)][ValidateSet('least-privilege', 'overbroad', 'unknown')][string]$AccessControlStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$RestoreVerificationStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArchiveObjectReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ObjectLockReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RetentionPolicyReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EncryptionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreTestReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Custodian,

    [ValidateRange(1, 2160)][int]$MaxAuditEvidenceAgeHours = 168,
    [ValidateRange(5, 1440)][int]$MaxCustodyEvidenceAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-evidence-custody',
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
    [pscustomobject]@{ Value = $ArchiveObjectReference; Description = 'ArchiveObjectReference' }
    [pscustomobject]@{ Value = $ObjectLockReference; Description = 'ObjectLockReference' }
    [pscustomobject]@{ Value = $RetentionPolicyReference; Description = 'RetentionPolicyReference' }
    [pscustomobject]@{ Value = $EncryptionReference; Description = 'EncryptionReference' }
    [pscustomobject]@{ Value = $AccessReviewReference; Description = 'AccessReviewReference' }
    [pscustomobject]@{ Value = $RestoreTestReference; Description = 'RestoreTestReference' }
    [pscustomobject]@{ Value = $Custodian; Description = 'Custodian' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedAuditPath = Resolve-LocalStatePath -Path $ChainAuditEvidencePath -Description 'ChainAuditEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedAuditPath -PathType Leaf)) {
    throw "Production assurance chain audit evidence is missing: $resolvedAuditPath"
}
$auditValidationArguments = @{
    EvidencePath = $resolvedAuditPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $auditValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') @auditValidationArguments 6>$null

$audit = Get-Content -Raw -LiteralPath $resolvedAuditPath | ConvertFrom-Json
if (
    [string]$audit.outcome -ne 'passed' -or
    [bool]$audit.chain.verified -ne $true -or
    [int]$audit.chain.firstSequence -ne 1 -or
    [int]$audit.chain.headSequence -lt 2 -or
    [int]$audit.chain.entryCount -ne [int]$audit.chain.headSequence -or
    [bool]$audit.decision.auditPassed -ne $true -or
    [string]$audit.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Evidence custody requires an exact passed production assurance chain audit.'
}

$archivedAt = $ArchivedAtUtc.ToUniversalTime()
$retentionUntil = $RetentionUntilUtc.ToUniversalTime()
$auditCollectedAt = ([DateTimeOffset]$audit.collectedAtUtc).ToUniversalTime()
$auditCompletedAt = ([DateTimeOffset]$audit.audit.completedAtUtc).ToUniversalTime()
$auditAge = $referenceNow - $auditCollectedAt
$custodyAge = $referenceNow - $archivedAt
$retentionDurationDays = [math]::Round(($retentionUntil - $archivedAt).TotalDays, 6)
if (
    $archivedAt -lt $auditCompletedAt -or
    $auditAge.TotalHours -lt -1 -or
    $auditAge.TotalHours -gt $MaxAuditEvidenceAgeHours -or
    $custodyAge.TotalMinutes -lt -5 -or
    $custodyAge.TotalMinutes -gt $MaxCustodyEvidenceAgeMinutes -or
    $retentionUntil -le $archivedAt
) {
    throw 'Evidence custody must follow the chain audit and use valid freshness and retention timestamps.'
}

$auditHash = (Get-FileHash -LiteralPath $resolvedAuditPath -Algorithm SHA256).Hash.ToLowerInvariant()
$normalizedArchivedAuditHash = $ArchivedAuditSha256.ToLowerInvariant()
$normalizedArchivedChainDigest = $ArchivedChainDigest.ToLowerInvariant()
$auditChecksumMatches = $normalizedArchivedAuditHash -eq $auditHash
$chainDigestMatches = $normalizedArchivedChainDigest -eq ([string]$audit.chain.digest).ToLowerInvariant()
$retentionMeetsPolicy = $retentionDurationDays -ge $RequiredRetentionDays
$hasFailure = (
    -not $auditChecksumMatches -or
    -not $chainDigestMatches -or
    -not $retentionMeetsPolicy -or
    $ArchiveWriteStatus -eq 'failed' -or
    $ObjectLockStatus -eq 'not-enforced' -or
    $RetentionPolicyStatus -eq 'inactive' -or
    $EncryptionStatus -eq 'failed' -or
    $AccessControlStatus -eq 'overbroad' -or
    $RestoreVerificationStatus -eq 'failed'
)
$hasUnknown = @(
    $ArchiveWriteStatus,
    $ObjectLockStatus,
    $RetentionPolicyStatus,
    $EncryptionStatus,
    $AccessControlStatus,
    $RestoreVerificationStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$custodyConfirmed = $outcome -eq 'passed'
$nextAction = if (-not $auditChecksumMatches -or -not $chainDigestMatches) {
    'quarantine-and-rebuild-archive'
}
elseif (
    $ArchiveWriteStatus -eq 'failed' -or
    $ObjectLockStatus -eq 'not-enforced' -or
    $RetentionPolicyStatus -eq 'inactive' -or
    -not $retentionMeetsPolicy
) {
    'complete-compliant-archive-before-continuing'
}
elseif ($EncryptionStatus -eq 'failed' -or $AccessControlStatus -eq 'overbroad') {
    'restrict-access-and-investigate'
}
elseif ($RestoreVerificationStatus -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}

$collectedAt = $referenceNow
$auditRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedAuditPath).Replace('\', '/')
$integrity = [ordered]@{
    chainAuditEvidenceSha256 = $auditHash
    chainAuditEvidenceIntegrityDigest = [string]$audit.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$audit.incidentId
    closureChangeId = [string]$audit.closureChangeId
    releaseVersion = [string]$audit.candidate.version
    sourceTag = [string]$audit.candidate.sourceTag
    controlPlaneImage = [string]$audit.candidate.controlPlaneImage
    edgeImage = [string]$audit.candidate.edgeImage
    policyVersion = [string]$audit.candidate.policyVersion
    chainDigest = [string]$audit.chain.digest
    chainEntryCount = [int]$audit.chain.entryCount
    headReviewSequence = [int]$audit.chain.headSequence
    auditCollectedAtUtc = $auditCollectedAt.ToString('o')
    archivedAtUtc = $archivedAt.ToString('o')
    retentionUntilUtc = $retentionUntil.ToString('o')
    requiredRetentionDays = $RequiredRetentionDays
    retentionDurationDays = $retentionDurationDays
    auditChecksumMatches = $auditChecksumMatches
    chainDigestMatches = $chainDigestMatches
    retentionMeetsPolicy = $retentionMeetsPolicy
    maxAuditEvidenceAgeHours = $MaxAuditEvidenceAgeHours
    maxCustodyEvidenceAgeMinutes = $MaxCustodyEvidenceAgeMinutes
    archiveWriteStatus = $ArchiveWriteStatus
    objectLockStatus = $ObjectLockStatus
    retentionPolicyStatus = $RetentionPolicyStatus
    encryptionStatus = $EncryptionStatus
    accessControlStatus = $AccessControlStatus
    restoreVerificationStatus = $RestoreVerificationStatus
    archivedAuditSha256 = $normalizedArchivedAuditHash
    archivedChainDigest = $normalizedArchivedChainDigest
    archiveObjectReference = $ArchiveObjectReference
    objectLockReference = $ObjectLockReference
    retentionPolicyReference = $RetentionPolicyReference
    encryptionReference = $EncryptionReference
    accessReviewReference = $AccessReviewReference
    restoreTestReference = $RestoreTestReference
    custodian = $Custodian
    collectedAtUtc = $collectedAt.ToString('o')
    custodyConfirmed = $custodyConfirmed
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'production-assurance-evidence-custody'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$audit.incidentId
    closureChangeId = [string]$audit.closureChangeId
    candidate = [ordered]@{
        version = [string]$audit.candidate.version
        sourceTag = [string]$audit.candidate.sourceTag
        controlPlaneImage = [string]$audit.candidate.controlPlaneImage
        edgeImage = [string]$audit.candidate.edgeImage
        policyVersion = [string]$audit.candidate.policyVersion
    }
    chainAuditEvidence = [ordered]@{
        relativePath = $auditRelativePath
        sha256 = $auditHash
        integrityDigest = [string]$audit.integrityDigest
        collectedAtUtc = $auditCollectedAt.ToString('o')
        chainDigest = [string]$audit.chain.digest
        chainEntryCount = [int]$audit.chain.entryCount
        headReviewSequence = [int]$audit.chain.headSequence
        outcome = [string]$audit.outcome
        auditPassed = [bool]$audit.decision.auditPassed
    }
    archive = [ordered]@{
        archivedAtUtc = $archivedAt.ToString('o')
        archivedAuditSha256 = $normalizedArchivedAuditHash
        archivedChainDigest = $normalizedArchivedChainDigest
        auditChecksumMatches = $auditChecksumMatches
        chainDigestMatches = $chainDigestMatches
        writeStatus = $ArchiveWriteStatus
        objectLockStatus = $ObjectLockStatus
        encryptionStatus = $EncryptionStatus
        accessControlStatus = $AccessControlStatus
        restoreVerificationStatus = $RestoreVerificationStatus
    }
    retention = [ordered]@{
        policyStatus = $RetentionPolicyStatus
        requiredDays = $RequiredRetentionDays
        durationDays = $retentionDurationDays
        untilUtc = $retentionUntil.ToString('o')
        meetsPolicy = $retentionMeetsPolicy
    }
    freshness = [ordered]@{
        maxAuditEvidenceAgeHours = $MaxAuditEvidenceAgeHours
        maxCustodyEvidenceAgeMinutes = $MaxCustodyEvidenceAgeMinutes
    }
    externalEvidence = [ordered]@{
        archiveObjectReference = $ArchiveObjectReference
        objectLockReference = $ObjectLockReference
        retentionPolicyReference = $RetentionPolicyReference
        encryptionReference = $EncryptionReference
        accessReviewReference = $AccessReviewReference
        restoreTestReference = $RestoreTestReference
        custodian = $Custodian
    }
    decision = [ordered]@{
        custodyConfirmed = $custodyConfirmed
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'custody-{0}-sequence-{1}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), [int]$audit.chain.headSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance evidence custody record already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production assurance evidence custody recorded at $evidencePath with outcome '$outcome'."
Write-Host "Audit checksum matches: $auditChecksumMatches; chain digest matches: $chainDigestMatches; retention meets policy: $retentionMeetsPolicy"
Write-Host 'No archive upload, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Evidence custody is not confirmed. Preserve local evidence and follow the recorded action.'
}
