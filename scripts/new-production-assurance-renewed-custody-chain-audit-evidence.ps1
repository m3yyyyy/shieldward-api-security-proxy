[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainHeadEvidencePath,
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$AuditCompletedAtUtc,

    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$ChainHeadGateStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$RenewedChainInventoryStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'missing', 'unknown')][string]$BaselineStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'missing', 'unknown')][string]$RenewalEvidenceStatus,
    [Parameter(Mandatory)][ValidateSet('preserved', 'changed', 'unknown')][string]$OriginalLineageStatus,
    [Parameter(Mandatory)][ValidateSet('retained', 'at-risk', 'unknown')][string]$EvidenceRetentionStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$IndependentReviewStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$AccessAuditStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$RestoreAuditStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainHeadGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RenewedChainInventoryReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BaselineReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RenewalEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OriginalLineageReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidenceRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$IndependentReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessAuditReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreAuditReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuditedBy,

    [ValidateRange(1, 8760)][int]$MaxHeadEvidenceAgeHours = 2208,
    [ValidateRange(5, 1440)][int]$MaxAuditAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-renewed-custody-chain-audit',
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

foreach ($reference in @(
    [pscustomobject]@{ Value = $ChainHeadGateReference; Description = 'ChainHeadGateReference' }
    [pscustomobject]@{ Value = $RenewedChainInventoryReference; Description = 'RenewedChainInventoryReference' }
    [pscustomobject]@{ Value = $BaselineReference; Description = 'BaselineReference' }
    [pscustomobject]@{ Value = $RenewalEvidenceReference; Description = 'RenewalEvidenceReference' }
    [pscustomobject]@{ Value = $OriginalLineageReference; Description = 'OriginalLineageReference' }
    [pscustomobject]@{ Value = $EvidenceRetentionReference; Description = 'EvidenceRetentionReference' }
    [pscustomobject]@{ Value = $IndependentReviewReference; Description = 'IndependentReviewReference' }
    [pscustomobject]@{ Value = $AccessAuditReference; Description = 'AccessAuditReference' }
    [pscustomobject]@{ Value = $RestoreAuditReference; Description = 'RestoreAuditReference' }
    [pscustomobject]@{ Value = $AuditedBy; Description = 'AuditedBy' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$resolvedHeadPath = Resolve-LocalStatePath -Path $ChainHeadEvidencePath -Description 'ChainHeadEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedHeadPath -PathType Leaf)) {
    throw "Renewed production assurance custody-review chain head is missing: $resolvedHeadPath"
}
$headValidationArguments = @{
    EvidencePath = $resolvedHeadPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
    $headValidationArguments.BaselinePath = $BaselinePath
}
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    $headValidationArguments.RenewalEvidencePath = $RenewalEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $headValidationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $headValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-recurring-evidence.ps1') @headValidationArguments 6>$null

$head = Get-Content -Raw -LiteralPath $resolvedHeadPath | ConvertFrom-Json
if (
    [string]$head.evidenceType -ne 'recurring-renewed-production-assurance-custody-review' -or
    [string]$head.outcome -ne 'passed' -or
    [bool]$head.decision.baselineLinkValid -ne $true -or
    [bool]$head.decision.predecessorLinkValid -ne $true -or
    [bool]$head.decision.originalLineagePreserved -ne $true -or
    [bool]$head.decision.custodyContinuityProven -ne $true -or
    [string]$head.decision.nextAction -ne 'continue-renewed-custody-reviews'
) {
    throw 'The renewed chain audit requires an exact passed recurring renewed custody-review head.'
}

$resolvedBaselinePath = if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    Resolve-LocalStatePath -Path ([string]$head.renewedCustodyBaseline.relativePath) -Description 'Recorded renewed custody baseline path'
}
else {
    Resolve-LocalStatePath -Path $BaselinePath -Description 'BaselinePath'
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
$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/')
if (
    $baselineRelativePath -ne [string]$head.renewedCustodyBaseline.relativePath -or
    $baselineHash -ne [string]$head.renewedCustodyBaseline.sha256 -or
    [string]$baseline.integrityDigest -ne [string]$head.renewedCustodyBaseline.integrityDigest -or
    [string]$baseline.renewedBaseline.lineageDigest -ne [string]$head.renewedCustodyBaseline.lineageDigest -or
    [string]$baseline.outcome -ne 'passed' -or
    [bool]$baseline.decision.baselineEstablished -ne $true
) {
    throw 'The exact passed renewed custody baseline no longer matches the chain head.'
}

$initialSequence = [int]$baseline.renewedBaseline.nextReviewSequence
$retentionUntil = ([DateTimeOffset]$head.retention.untilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$head.schedule.nextReviewDueAtUtc).ToUniversalTime()
$visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entriesDescending = [System.Collections.Generic.List[object]]::new()
$currentPath = $resolvedHeadPath
while ($true) {
    if (-not $visited.Add($currentPath)) {
        throw 'The renewed production assurance custody-review chain contains a cycle.'
    }
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        throw "The renewed production assurance custody-review chain is missing an artifact: $currentPath"
    }

    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $currentType = [string]$current.evidenceType
    $currentSequence = [int]$current.review.sequence
    if (
        $currentType -ne 'renewed-production-assurance-custody-review' -and
        $currentType -ne 'recurring-renewed-production-assurance-custody-review'
    ) {
        throw "The renewed custody-review chain contains unsupported evidence type '$currentType'."
    }
    if (
        [string]$current.productionContext -ne $ExpectedProductionContext -or
        [string]$current.namespace -ne 'shieldward' -or
        [string]$current.outcome -ne 'passed' -or
        [bool]$current.decision.baselineLinkValid -ne $true -or
        [bool]$current.decision.originalLineagePreserved -ne $true -or
        [bool]$current.decision.custodyContinuityProven -ne $true -or
        [string]$current.decision.nextAction -ne 'continue-renewed-custody-reviews' -or
        [string]$current.changeId -ne [string]$head.changeId -or
        [string]$current.incidentId -ne [string]$head.incidentId -or
        [string]$current.closureChangeId -ne [string]$head.closureChangeId -or
        [string]$current.candidate.version -ne [string]$head.candidate.version -or
        [string]$current.candidate.sourceTag -ne [string]$head.candidate.sourceTag -or
        [string]$current.candidate.controlPlaneImage -ne [string]$head.candidate.controlPlaneImage -or
        [string]$current.candidate.edgeImage -ne [string]$head.candidate.edgeImage -or
        [string]$current.candidate.policyVersion -ne [string]$head.candidate.policyVersion
    ) {
        throw 'The renewed custody-review chain changed identity, candidate, or passed state.'
    }
    if (
        [string]$current.renewedCustodyBaseline.sha256 -ne [string]$head.renewedCustodyBaseline.sha256 -or
        [string]$current.renewedCustodyBaseline.integrityDigest -ne [string]$head.renewedCustodyBaseline.integrityDigest -or
        [string]$current.renewedCustodyBaseline.lineageDigest -ne [string]$head.renewedCustodyBaseline.lineageDigest -or
        [string]$current.renewalEvidence.sha256 -ne [string]$head.renewalEvidence.sha256 -or
        [string]$current.renewalEvidence.integrityDigest -ne [string]$head.renewalEvidence.integrityDigest -or
        [string]$current.originalCustody.sha256 -ne [string]$head.originalCustody.sha256 -or
        [string]$current.originalCustody.integrityDigest -ne [string]$head.originalCustody.integrityDigest -or
        [string]$current.originalCustody.chainDigest -ne [string]$head.originalCustody.chainDigest -or
        [string]$current.priorReviewChain.digest -ne [string]$head.priorReviewChain.digest -or
        [int]$current.priorReviewChain.headSequence -ne [int]$head.priorReviewChain.headSequence -or
        ([DateTimeOffset]$current.retention.untilUtc).ToUniversalTime().ToString('o') -ne $retentionUntil.ToString('o')
    ) {
        throw 'The renewed custody-review chain changed its baseline, renewal, original lineage, or retention boundary.'
    }

    $currentRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $currentPath).Replace('\', '/')
    $currentHash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $entriesDescending.Add([ordered]@{
        evidenceType = $currentType
        sequence = $currentSequence
        relativePath = $currentRelativePath
        sha256 = $currentHash
        integrityDigest = [string]$current.integrityDigest
        linkDigest = [string]$current.review.linkDigest
        collectedAtUtc = ([DateTimeOffset]$current.collectedAtUtc).ToUniversalTime().ToString('o')
        completedAtUtc = ([DateTimeOffset]$current.review.completedAtUtc).ToUniversalTime().ToString('o')
        expectedDueAtUtc = if ($currentType -eq 'renewed-production-assurance-custody-review') {
            ([DateTimeOffset]$current.review.scheduledDueAtUtc).ToUniversalTime().ToString('o')
        }
        else {
            ([DateTimeOffset]$current.review.expectedDueAtUtc).ToUniversalTime().ToString('o')
        }
        nextReviewDueAtUtc = ([DateTimeOffset]$current.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o')
        outcome = [string]$current.outcome
    })

    if ($currentType -eq 'renewed-production-assurance-custody-review') {
        if ($currentSequence -ne $initialSequence) {
            throw 'The renewed custody-review chain does not begin at the baseline next sequence.'
        }
        break
    }
    if ([int]$current.review.previousSequence -ne ($currentSequence - 1)) {
        throw 'The recurring renewed custody-review chain contains a sequence gap.'
    }
    $previousPath = Resolve-LocalStatePath -Path ([string]$current.previousReviewEvidence.relativePath) -Description 'Recorded previous renewed custody review path'
    if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
        throw "The recurring renewed custody-review chain is missing a predecessor: $previousPath"
    }
    $previousHash = (Get-FileHash -LiteralPath $previousPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $previousArtifact = Get-Content -Raw -LiteralPath $previousPath | ConvertFrom-Json
    if (
        $previousHash -ne [string]$current.previousReviewEvidence.sha256 -or
        [string]$previousArtifact.integrityDigest -ne [string]$current.previousReviewEvidence.integrityDigest -or
        [string]$previousArtifact.review.linkDigest -ne [string]$current.previousReviewEvidence.linkDigest -or
        [int]$previousArtifact.review.sequence -ne [int]$current.previousReviewEvidence.reviewSequence -or
        [int]$previousArtifact.review.sequence -ne ($currentSequence - 1)
    ) {
        throw 'The recurring renewed custody-review predecessor link is invalid.'
    }
    $currentPath = $previousPath
}

$chainEntries = @($entriesDescending)
[array]::Reverse($chainEntries)
$expectedEntryCount = ([int]$head.review.sequence - $initialSequence) + 1
if ($chainEntries.Count -ne $expectedEntryCount) {
    throw 'The renewed custody-review chain count does not match its sequence range.'
}
for ($index = 0; $index -lt $chainEntries.Count; $index++) {
    if ([int]$chainEntries[$index].sequence -ne ($initialSequence + $index)) {
        throw 'The renewed custody-review chain inventory is not contiguous from its baseline sequence.'
    }
}

$auditCompletedAt = $AuditCompletedAtUtc.ToUniversalTime()
$headCollectedAt = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()
$headCompletedAt = ([DateTimeOffset]$head.review.completedAtUtc).ToUniversalTime()
$headAge = $referenceNow - $headCollectedAt
$auditAge = $referenceNow - $auditCompletedAt
if (
    $auditCompletedAt -lt $headCompletedAt -or
    $auditCompletedAt -ge $retentionUntil -or
    $headAge.TotalHours -lt -1 -or
    $headAge.TotalHours -gt $MaxHeadEvidenceAgeHours -or
    $auditAge.TotalMinutes -lt -5 -or
    $auditAge.TotalMinutes -gt $MaxAuditAgeMinutes
) {
    throw 'The renewed custody chain audit must follow the head and remain inside its freshness and retention boundary.'
}

$hasFailure = (
    $ChainHeadGateStatus -eq 'failed' -or
    $RenewedChainInventoryStatus -eq 'incomplete' -or
    $BaselineStatus -eq 'missing' -or
    $RenewalEvidenceStatus -eq 'missing' -or
    $OriginalLineageStatus -eq 'changed' -or
    $EvidenceRetentionStatus -eq 'at-risk' -or
    $IndependentReviewStatus -eq 'failed' -or
    $AccessAuditStatus -eq 'failed' -or
    $RestoreAuditStatus -eq 'failed'
)
$hasUnknown = @(
    $ChainHeadGateStatus,
    $RenewedChainInventoryStatus,
    $BaselineStatus,
    $RenewalEvidenceStatus,
    $OriginalLineageStatus,
    $EvidenceRetentionStatus,
    $IndependentReviewStatus,
    $AccessAuditStatus,
    $RestoreAuditStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$auditPassed = $outcome -eq 'passed'
$nextAction = if ($RenewedChainInventoryStatus -eq 'incomplete' -or $BaselineStatus -eq 'missing' -or $RenewalEvidenceStatus -eq 'missing') {
    'restore-evidence-and-investigate'
}
elseif ($OriginalLineageStatus -eq 'changed') {
    'preserve-chain-and-investigate'
}
elseif ($EvidenceRetentionStatus -eq 'at-risk') {
    'renew-retention-before-continuing'
}
elseif ($AccessAuditStatus -eq 'failed') {
    'restrict-access-and-investigate'
}
elseif ($RestoreAuditStatus -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif ($ChainHeadGateStatus -eq 'failed' -or $IndependentReviewStatus -eq 'failed') {
    'stop-and-investigate-renewed-custody-chain'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-renewed-custody-reviews'
}

$collectedAt = $referenceNow
$headHash = (Get-FileHash -LiteralPath $resolvedHeadPath -Algorithm SHA256).Hash.ToLowerInvariant()
$headRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedHeadPath).Replace('\', '/')
$chainDigest = Get-Sha256Text -Text ($chainEntries | ConvertTo-Json -Depth 5 -Compress)
$integrity = [ordered]@{
    chainHeadEvidenceSha256 = $headHash
    chainHeadEvidenceIntegrityDigest = [string]$head.integrityDigest
    renewedBaselineSha256 = $baselineHash
    renewedBaselineIntegrityDigest = [string]$baseline.integrityDigest
    renewedLineageDigest = [string]$baseline.renewedBaseline.lineageDigest
    renewalEvidenceSha256 = [string]$head.renewalEvidence.sha256
    renewalEvidenceIntegrityDigest = [string]$head.renewalEvidence.integrityDigest
    originalCustodySha256 = [string]$head.originalCustody.sha256
    originalCustodyIntegrityDigest = [string]$head.originalCustody.integrityDigest
    originalCustodyChainDigest = [string]$head.originalCustody.chainDigest
    priorReviewChainDigest = [string]$head.priorReviewChain.digest
    chainDigest = $chainDigest
    chainEntryCount = $chainEntries.Count
    initialReviewSequence = $initialSequence
    headReviewSequence = [int]$head.review.sequence
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$head.changeId
    incidentId = [string]$head.incidentId
    closureChangeId = [string]$head.closureChangeId
    releaseVersion = [string]$head.candidate.version
    sourceTag = [string]$head.candidate.sourceTag
    controlPlaneImage = [string]$head.candidate.controlPlaneImage
    edgeImage = [string]$head.candidate.edgeImage
    policyVersion = [string]$head.candidate.policyVersion
    retentionUntilUtc = $retentionUntil.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    headCollectedAtUtc = $headCollectedAt.ToString('o')
    auditCompletedAtUtc = $auditCompletedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxHeadEvidenceAgeHours = $MaxHeadEvidenceAgeHours
    maxAuditAgeMinutes = $MaxAuditAgeMinutes
    chainHeadGateStatus = $ChainHeadGateStatus
    renewedChainInventoryStatus = $RenewedChainInventoryStatus
    baselineStatus = $BaselineStatus
    renewalEvidenceStatus = $RenewalEvidenceStatus
    originalLineageStatus = $OriginalLineageStatus
    evidenceRetentionStatus = $EvidenceRetentionStatus
    independentReviewStatus = $IndependentReviewStatus
    accessAuditStatus = $AccessAuditStatus
    restoreAuditStatus = $RestoreAuditStatus
    chainHeadGateReference = $ChainHeadGateReference
    renewedChainInventoryReference = $RenewedChainInventoryReference
    baselineReference = $BaselineReference
    renewalEvidenceReference = $RenewalEvidenceReference
    originalLineageReference = $OriginalLineageReference
    evidenceRetentionReference = $EvidenceRetentionReference
    independentReviewReference = $IndependentReviewReference
    accessAuditReference = $AccessAuditReference
    restoreAuditReference = $RestoreAuditReference
    auditedBy = $AuditedBy
    chainVerified = $true
    baselineVerified = $true
    renewalVerified = $true
    originalLineageVerified = $true
    auditPassed = $auditPassed
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'renewed-production-assurance-custody-chain-audit'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$head.changeId
    incidentId = [string]$head.incidentId
    closureChangeId = [string]$head.closureChangeId
    candidate = $head.candidate
    chainHeadEvidence = [ordered]@{
        relativePath = $headRelativePath
        sha256 = $headHash
        integrityDigest = [string]$head.integrityDigest
        collectedAtUtc = $headCollectedAt.ToString('o')
        reviewSequence = [int]$head.review.sequence
        outcome = [string]$head.outcome
        custodyContinuityProven = [bool]$head.decision.custodyContinuityProven
    }
    renewedCustodyBaseline = $head.renewedCustodyBaseline
    renewalEvidence = $head.renewalEvidence
    originalCustody = $head.originalCustody
    priorReviewChain = $head.priorReviewChain
    chain = [ordered]@{
        verified = $true
        baselineVerified = $true
        renewalVerified = $true
        originalLineageVerified = $true
        initialSequence = $initialSequence
        headSequence = [int]$head.review.sequence
        entryCount = $chainEntries.Count
        digest = $chainDigest
        entries = $chainEntries
    }
    schedule = [ordered]@{
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        nextReviewWithinRetention = [bool]$head.schedule.nextReviewWithinRetention
    }
    retention = [ordered]@{
        untilUtc = $retentionUntil.ToString('o')
        remainingDays = [double]$head.retention.remainingDays
        remainingMeetsPolicy = [bool]$head.retention.remainingMeetsPolicy
    }
    audit = [ordered]@{
        completedAtUtc = $auditCompletedAt.ToString('o')
        maxHeadEvidenceAgeHours = $MaxHeadEvidenceAgeHours
        maxAuditAgeMinutes = $MaxAuditAgeMinutes
        chainHeadGateStatus = $ChainHeadGateStatus
        renewedChainInventoryStatus = $RenewedChainInventoryStatus
        baselineStatus = $BaselineStatus
        renewalEvidenceStatus = $RenewalEvidenceStatus
        originalLineageStatus = $OriginalLineageStatus
        evidenceRetentionStatus = $EvidenceRetentionStatus
        independentReviewStatus = $IndependentReviewStatus
        accessAuditStatus = $AccessAuditStatus
        restoreAuditStatus = $RestoreAuditStatus
    }
    externalEvidence = [ordered]@{
        chainHeadGateReference = $ChainHeadGateReference
        renewedChainInventoryReference = $RenewedChainInventoryReference
        baselineReference = $BaselineReference
        renewalEvidenceReference = $RenewalEvidenceReference
        originalLineageReference = $OriginalLineageReference
        evidenceRetentionReference = $EvidenceRetentionReference
        independentReviewReference = $IndependentReviewReference
        accessAuditReference = $AccessAuditReference
        restoreAuditReference = $RestoreAuditReference
        auditedBy = $AuditedBy
    }
    decision = [ordered]@{
        chainVerified = $true
        baselineVerified = $true
        renewalVerified = $true
        originalLineageVerified = $true
        auditPassed = $auditPassed
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'renewed-custody-chain-audit-{0}-sequence-{1}.json' -f $collectedAt.ToString('yyyyMMddTHHmmssZ'), [int]$head.review.sequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Renewed production assurance custody chain-audit evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Renewed production assurance custody chain-audit evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Verified renewed review sequences $initialSequence through $($head.review.sequence); entries: $($chainEntries.Count); next action: $nextAction"
Write-Host 'No scheduler, archive, custody, retention, access, restore, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'The renewed custody chain audit did not pass. Preserve the chain and follow the recorded action.'
}
