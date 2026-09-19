[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousReviewEvidencePath,
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
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

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousReviewGateReference,
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
    [string]$OutputDirectory = '.shieldward/production-assurance-generation-5-custody-recurring',
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

foreach ($reference in @(
    [pscustomobject]@{ Value = $PreviousReviewGateReference; Description = 'PreviousReviewGateReference' }
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

$resolvedPreviousPath = Resolve-LocalStatePath -Path $PreviousReviewEvidencePath -Description 'PreviousReviewEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Previous generation-5 custody-review evidence is missing: $resolvedPreviousPath"
}
$previous = Get-Content -Raw -LiteralPath $resolvedPreviousPath | ConvertFrom-Json
$previousType = [string]$previous.evidenceType
$previousValidationArguments = @{
    EvidencePath = $resolvedPreviousPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
    $previousValidationArguments.BaselinePath = $BaselinePath
}
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    $previousValidationArguments.RenewalEvidencePath = $RenewalEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $previousValidationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $previousValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
if ($previousType -eq 'generation-5-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-review-evidence.ps1') @previousValidationArguments 6>$null
}
elseif ($previousType -eq 'recurring-generation-5-production-assurance-custody-review') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-recurring-evidence.ps1') @previousValidationArguments 6>$null
}
else {
    throw "Previous generation-5 custody-review evidence type '$previousType' is unsupported."
}

if (
    [string]$previous.outcome -ne 'passed' -or
    [int]$previous.generation5CustodyBaseline.generation -ne 5 -or
    [int]$previous.generation5CustodyBaseline.renewalSequence -ne 4 -or
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
    [bool]$previous.decision.baselineLinkValid -ne $true -or
    [bool]$previous.decision.inheritedLineagePreserved -ne $true -or
    [bool]$previous.decision.custodyContinuityProven -ne $true -or
    [string]$previous.decision.nextAction -ne 'continue-generation-5-custody-reviews'
) {
    throw 'Recurring generation-5 custody review requires the exact passed previous review evidence.'
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
    throw 'Recurring generation-5 custody review must follow its exact predecessor and use current freshness-bounded observations.'
}

$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddHours(-1) -and
    $completedAt -le $expectedDueAt.AddHours($CompletionGraceHours)
)
$previousSequence = [int]$previous.review.sequence
$reviewSequence = $previousSequence + 1
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
    'escalate-missed-generation-5-custody-review'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-generation-5-custody-reviews'
}

$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
$reviewLink = [ordered]@{
    previousReviewEvidenceSha256 = $previousHash
    previousReviewIntegrityDigest = [string]$previous.integrityDigest
    previousReviewLinkDigest = [string]$previous.review.linkDigest
    generation5BaselineSha256 = [string]$previous.generation5CustodyBaseline.sha256
    generation5LineageDigest = [string]$previous.generation5CustodyBaseline.lineageDigest
    previousReviewSequence = $previousSequence
    reviewSequence = $reviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
}
$reviewLinkDigest = Get-Sha256Text -Text ($reviewLink | ConvertTo-Json -Depth 4 -Compress)

$collectedAt = $referenceNow
$integrity = [ordered]@{
    previousReviewEvidenceType = $previousType
    previousReviewEvidenceSha256 = $previousHash
    previousReviewIntegrityDigest = [string]$previous.integrityDigest
    previousReviewLinkDigest = [string]$previous.review.linkDigest
    previousReviewSequence = $previousSequence
    generation5BaselineSha256 = [string]$previous.generation5CustodyBaseline.sha256
    generation5BaselineIntegrityDigest = [string]$previous.generation5CustodyBaseline.integrityDigest
    generation5LineageDigest = [string]$previous.generation5CustodyBaseline.lineageDigest
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
    previousBaselineSha256 = [string]$previous.inheritedLineage.generation4BaselineSha256
    previousBaselineIntegrityDigest = [string]$previous.inheritedLineage.generation4BaselineIntegrityDigest
    previousLineageDigest = [string]$previous.inheritedLineage.generation4LineageDigest
    previousRenewalEvidenceSha256 = [string]$previous.inheritedLineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$previous.inheritedLineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineageDigest = Get-Sha256Text -Text ($previous.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress)
    previousReviewChainDigest = [string]$previous.inheritedLineage.generation4ReviewChainDigest
    baselineGeneration = [int]$previous.generation5CustodyBaseline.generation
    renewalSequence = [int]$previous.generation5CustodyBaseline.renewalSequence
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
    previousReviewGateReference = $PreviousReviewGateReference
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
    predecessorLinkValid = $true
    inheritedLineagePreserved = $true
    custodyContinuityProven = $custodyContinuityProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'recurring-generation-5-production-assurance-custody-review'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$previous.changeId
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    candidate = $previous.candidate
    previousReviewEvidence = [ordered]@{
        evidenceType = $previousType
        relativePath = $previousRelativePath
        sha256 = $previousHash
        integrityDigest = [string]$previous.integrityDigest
        linkDigest = [string]$previous.review.linkDigest
        collectedAtUtc = $previousCollectedAt.ToString('o')
        reviewSequence = $previousSequence
        outcome = [string]$previous.outcome
        custodyContinuityProven = [bool]$previous.decision.custodyContinuityProven
    }
    generation5CustodyBaseline = $previous.generation5CustodyBaseline
    renewalEvidence = $previous.renewalEvidence
    inheritedLineage = $previous.inheritedLineage
    review = [ordered]@{
        sequence = $reviewSequence
        previousSequence = $previousSequence
        expectedDueAtUtc = $expectedDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceHours = $CompletionGraceHours
        onTime = $reviewOnTime
        maxPreviousEvidenceAgeHours = $MaxPreviousEvidenceAgeHours
        maxReviewAgeMinutes = $MaxReviewAgeMinutes
        linkDigest = $reviewLinkDigest
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
        previousReviewGateReference = $PreviousReviewGateReference
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
        predecessorLinkValid = $true
        inheritedLineagePreserved = $true
        custodyContinuityProven = $custodyContinuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'generation-5-custody-review-{0}-sequence-{1}.json' -f $collectedAt.ToString('yyyyMMddTHHmmssZ'), $reviewSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Recurring generation-5 custody-review evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Recurring generation-5 custody-review evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review sequence $reviewSequence follows exact predecessor $previousSequence; retention remaining: $retentionRemainingDays days."
Write-Host 'No review was scheduled and no archive, object-lock, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Generation-5 custody continuity is not proven. Preserve evidence and follow the recorded action.'
}


