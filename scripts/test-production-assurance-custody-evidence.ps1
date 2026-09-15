[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainAuditEvidencePath = '',
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
    throw "Production assurance evidence custody record is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'production-assurance-evidence-custody'
) {
    throw 'The supplied production assurance evidence custody record is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The evidence custody record targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The evidence custody record uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedAuditPath = if ([string]::IsNullOrWhiteSpace($ChainAuditEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.chainAuditEvidence.relativePath) -Description 'Recorded chain audit evidence path'
}
else {
    Resolve-LocalStatePath -Path $ChainAuditEvidencePath -Description 'ChainAuditEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedAuditPath -PathType Leaf)) {
    throw "Recorded production assurance chain audit evidence is missing: $resolvedAuditPath"
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
$auditRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedAuditPath).Replace('\', '/')
$auditHash = (Get-FileHash -LiteralPath $resolvedAuditPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $auditRelativePath -ne [string]$evidence.chainAuditEvidence.relativePath -or
    $auditHash -ne [string]$evidence.chainAuditEvidence.sha256 -or
    [string]$audit.integrityDigest -ne [string]$evidence.chainAuditEvidence.integrityDigest -or
    ([DateTimeOffset]$audit.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.chainAuditEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$audit.chain.digest -ne [string]$evidence.chainAuditEvidence.chainDigest -or
    [int]$audit.chain.entryCount -ne [int]$evidence.chainAuditEvidence.chainEntryCount -or
    [int]$audit.chain.headSequence -ne [int]$evidence.chainAuditEvidence.headReviewSequence -or
    [string]$evidence.chainAuditEvidence.outcome -ne 'passed' -or
    [bool]$evidence.chainAuditEvidence.auditPassed -ne $true
) {
    throw 'The exact passed production assurance chain audit no longer matches custody evidence.'
}
if (
    [string]$audit.outcome -ne 'passed' -or
    [bool]$audit.chain.verified -ne $true -or
    [int]$audit.chain.firstSequence -ne 1 -or
    [int]$audit.chain.headSequence -lt 2 -or
    [int]$audit.chain.entryCount -ne [int]$audit.chain.headSequence -or
    [bool]$audit.decision.auditPassed -ne $true -or
    [string]$audit.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Evidence custody requires a passed production assurance chain audit.'
}
if (
    [string]$evidence.incidentId -ne [string]$audit.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$audit.closureChangeId -or
    [string]$evidence.candidate.version -ne [string]$audit.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$audit.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$audit.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$audit.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$audit.candidate.policyVersion
) {
    throw 'The evidence custody identity or candidate does not match its chain audit.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'archive write'; Actual = [string]$evidence.archive.writeStatus; Allowed = @('completed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'object lock'; Actual = [string]$evidence.archive.objectLockStatus; Allowed = @('enforced', 'not-enforced', 'unknown') }
    [pscustomobject]@{ Name = 'retention policy'; Actual = [string]$evidence.retention.policyStatus; Allowed = @('active', 'inactive', 'unknown') }
    [pscustomobject]@{ Name = 'encryption'; Actual = [string]$evidence.archive.encryptionStatus; Allowed = @('verified', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access control'; Actual = [string]$evidence.archive.accessControlStatus; Allowed = @('least-privilege', 'overbroad', 'unknown') }
    [pscustomobject]@{ Name = 'restore verification'; Actual = [string]$evidence.archive.restoreVerificationStatus; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The evidence custody record contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.archiveObjectReference; Description = 'Archive object reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.objectLockReference; Description = 'Object lock reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.retentionPolicyReference; Description = 'Retention policy reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.encryptionReference; Description = 'Encryption reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessReviewReference; Description = 'Access review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreTestReference; Description = 'Restore test reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.custodian; Description = 'Custodian' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$archivedAt = ([DateTimeOffset]$evidence.archive.archivedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
$auditCollectedAt = ([DateTimeOffset]$audit.collectedAtUtc).ToUniversalTime()
$auditCompletedAt = ([DateTimeOffset]$audit.audit.completedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$retentionDurationDays = [math]::Round(($retentionUntil - $archivedAt).TotalDays, 6)
$auditAgeAtCollection = $collectedAt - $auditCollectedAt
$custodyAgeAtCollection = $collectedAt - $archivedAt
if (
    $archivedAt -lt $auditCompletedAt -or
    $retentionUntil -le $archivedAt -or
    [int]$evidence.retention.requiredDays -lt 30 -or
    [int]$evidence.retention.requiredDays -gt 3650 -or
    [double]$evidence.retention.durationDays -ne $retentionDurationDays -or
    [int]$evidence.freshness.maxAuditEvidenceAgeHours -lt 1 -or
    [int]$evidence.freshness.maxAuditEvidenceAgeHours -gt 2160 -or
    $auditAgeAtCollection.TotalHours -lt -1 -or
    $auditAgeAtCollection.TotalHours -gt [int]$evidence.freshness.maxAuditEvidenceAgeHours -or
    [int]$evidence.freshness.maxCustodyEvidenceAgeMinutes -lt 5 -or
    [int]$evidence.freshness.maxCustodyEvidenceAgeMinutes -gt 1440 -or
    $custodyAgeAtCollection.TotalMinutes -lt -5 -or
    $custodyAgeAtCollection.TotalMinutes -gt [int]$evidence.freshness.maxCustodyEvidenceAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The production assurance evidence custody timing, retention, or freshness boundary is invalid.'
}

$normalizedArchivedAuditHash = ([string]$evidence.archive.archivedAuditSha256).ToLowerInvariant()
$normalizedArchivedChainDigest = ([string]$evidence.archive.archivedChainDigest).ToLowerInvariant()
if (
    $normalizedArchivedAuditHash -notmatch '^[a-f0-9]{64}$' -or
    $normalizedArchivedChainDigest -notmatch '^[a-f0-9]{64}$'
) {
    throw 'The evidence custody record contains an invalid archived digest.'
}
$auditChecksumMatches = $normalizedArchivedAuditHash -eq $auditHash
$chainDigestMatches = $normalizedArchivedChainDigest -eq ([string]$audit.chain.digest).ToLowerInvariant()
$retentionMeetsPolicy = $retentionDurationDays -ge [int]$evidence.retention.requiredDays
if (
    [bool]$evidence.archive.auditChecksumMatches -ne $auditChecksumMatches -or
    [bool]$evidence.archive.chainDigestMatches -ne $chainDigestMatches -or
    [bool]$evidence.retention.meetsPolicy -ne $retentionMeetsPolicy
) {
    throw 'The archived checksum, chain digest, or retention decision is inconsistent with custody evidence.'
}

$hasFailure = (
    -not $auditChecksumMatches -or
    -not $chainDigestMatches -or
    -not $retentionMeetsPolicy -or
    [string]$evidence.archive.writeStatus -eq 'failed' -or
    [string]$evidence.archive.objectLockStatus -eq 'not-enforced' -or
    [string]$evidence.retention.policyStatus -eq 'inactive' -or
    [string]$evidence.archive.encryptionStatus -eq 'failed' -or
    [string]$evidence.archive.accessControlStatus -eq 'overbroad' -or
    [string]$evidence.archive.restoreVerificationStatus -eq 'failed'
)
$hasUnknown = @(
    [string]$evidence.archive.writeStatus,
    [string]$evidence.archive.objectLockStatus,
    [string]$evidence.retention.policyStatus,
    [string]$evidence.archive.encryptionStatus,
    [string]$evidence.archive.accessControlStatus,
    [string]$evidence.archive.restoreVerificationStatus
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedCustodyConfirmed = $expectedOutcome -eq 'passed'
$expectedNextAction = if (-not $auditChecksumMatches -or -not $chainDigestMatches) {
    'quarantine-and-rebuild-archive'
}
elseif (
    [string]$evidence.archive.writeStatus -eq 'failed' -or
    [string]$evidence.archive.objectLockStatus -eq 'not-enforced' -or
    [string]$evidence.retention.policyStatus -eq 'inactive' -or
    -not $retentionMeetsPolicy
) {
    'complete-compliant-archive-before-continuing'
}
elseif (
    [string]$evidence.archive.encryptionStatus -eq 'failed' -or
    [string]$evidence.archive.accessControlStatus -eq 'overbroad'
) {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.archive.restoreVerificationStatus -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.custodyConfirmed -ne $expectedCustodyConfirmed -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The production assurance evidence custody outcome or action is inconsistent with recorded evidence.'
}

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
    requiredRetentionDays = [int]$evidence.retention.requiredDays
    retentionDurationDays = $retentionDurationDays
    auditChecksumMatches = $auditChecksumMatches
    chainDigestMatches = $chainDigestMatches
    retentionMeetsPolicy = $retentionMeetsPolicy
    maxAuditEvidenceAgeHours = [int]$evidence.freshness.maxAuditEvidenceAgeHours
    maxCustodyEvidenceAgeMinutes = [int]$evidence.freshness.maxCustodyEvidenceAgeMinutes
    archiveWriteStatus = [string]$evidence.archive.writeStatus
    objectLockStatus = [string]$evidence.archive.objectLockStatus
    retentionPolicyStatus = [string]$evidence.retention.policyStatus
    encryptionStatus = [string]$evidence.archive.encryptionStatus
    accessControlStatus = [string]$evidence.archive.accessControlStatus
    restoreVerificationStatus = [string]$evidence.archive.restoreVerificationStatus
    archivedAuditSha256 = $normalizedArchivedAuditHash
    archivedChainDigest = $normalizedArchivedChainDigest
    archiveObjectReference = [string]$evidence.externalEvidence.archiveObjectReference
    objectLockReference = [string]$evidence.externalEvidence.objectLockReference
    retentionPolicyReference = [string]$evidence.externalEvidence.retentionPolicyReference
    encryptionReference = [string]$evidence.externalEvidence.encryptionReference
    accessReviewReference = [string]$evidence.externalEvidence.accessReviewReference
    restoreTestReference = [string]$evidence.externalEvidence.restoreTestReference
    custodian = [string]$evidence.externalEvidence.custodian
    collectedAtUtc = $collectedAt.ToString('o')
    custodyConfirmed = $expectedCustodyConfirmed
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance evidence custody integrity digest is invalid.'
}

Write-Host "Production assurance evidence custody validation passed with outcome '$expectedOutcome'."
Write-Host "Audit checksum matches: $auditChecksumMatches; chain digest matches: $chainDigestMatches; retention meets policy: $retentionMeetsPolicy"
Write-Host 'This validator is read-only and does not upload, retain, delete, restore, or change production evidence.'
