[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainHeadEvidencePath = '',
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
    throw "Production assurance custody chain-audit evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'production-assurance-custody-chain-audit'
) {
    throw 'The supplied production assurance custody chain-audit evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The custody chain audit targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The custody chain audit uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedHeadPath = if ([string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.chainHeadEvidence.relativePath) -Description 'Recorded custody chain head evidence path'
}
else {
    Resolve-LocalStatePath -Path $ChainHeadEvidencePath -Description 'ChainHeadEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedHeadPath -PathType Leaf)) {
    throw "Recorded production assurance custody chain head is missing: $resolvedHeadPath"
}
$headValidationArguments = @{
    EvidencePath = $resolvedHeadPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $headValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-recurring-evidence.ps1') @headValidationArguments 6>$null

$head = Get-Content -Raw -LiteralPath $resolvedHeadPath | ConvertFrom-Json
$headRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedHeadPath).Replace('\', '/')
$headHash = (Get-FileHash -LiteralPath $resolvedHeadPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $headRelativePath -ne [string]$evidence.chainHeadEvidence.relativePath -or
    $headHash -ne [string]$evidence.chainHeadEvidence.sha256 -or
    [string]$head.integrityDigest -ne [string]$evidence.chainHeadEvidence.integrityDigest -or
    ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.chainHeadEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$head.review.sequence -ne [int]$evidence.chainHeadEvidence.reviewSequence -or
    [string]$evidence.chainHeadEvidence.outcome -ne 'passed' -or
    [bool]$evidence.chainHeadEvidence.custodyContinuityProven -ne $true
) {
    throw 'The exact passed production assurance custody chain head no longer matches the audit evidence.'
}
if (
    [string]$head.outcome -ne 'passed' -or
    [int]$head.review.sequence -lt 2 -or
    [bool]$head.decision.custodyLinkValid -ne $true -or
    [bool]$head.decision.custodyContinuityProven -ne $true -or
    [string]$head.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'The custody chain audit requires a passed recurring custody-review head.'
}
if (
    [string]$evidence.incidentId -ne [string]$head.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$head.closureChangeId -or
    [string]$evidence.candidate.version -ne [string]$head.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$head.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$head.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$head.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$head.candidate.policyVersion
) {
    throw 'The custody chain audit identity or candidate does not match its head.'
}

$headRootCustody = $head.rootCustodyEvidence
$rootCustodyCollectedAt = ([DateTimeOffset]$headRootCustody.collectedAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$headRootCustody.retentionUntilUtc).ToUniversalTime()
if (
    [string]$headRootCustody.relativePath -ne [string]$evidence.rootCustodyEvidence.relativePath -or
    [string]$headRootCustody.sha256 -ne [string]$evidence.rootCustodyEvidence.sha256 -or
    [string]$headRootCustody.integrityDigest -ne [string]$evidence.rootCustodyEvidence.integrityDigest -or
    $rootCustodyCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.rootCustodyEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$headRootCustody.chainDigest -ne [string]$evidence.rootCustodyEvidence.chainDigest -or
    [int]$headRootCustody.headReviewSequence -ne [int]$evidence.rootCustodyEvidence.headReviewSequence -or
    $retentionUntil.ToString('o') -ne ([DateTimeOffset]$evidence.rootCustodyEvidence.retentionUntilUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.rootCustodyEvidence.outcome -ne 'passed' -or
    [bool]$evidence.rootCustodyEvidence.custodyConfirmed -ne $true
) {
    throw 'The exact root production assurance custody evidence no longer matches the audit evidence.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'chain head gate'; Actual = [string]$evidence.audit.chainHeadGateStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'chain inventory'; Actual = [string]$evidence.audit.chainInventoryStatus; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'root custody'; Actual = [string]$evidence.audit.rootCustodyStatus; Allowed = @('confirmed', 'invalid', 'unknown') }
    [pscustomobject]@{ Name = 'evidence retention'; Actual = [string]$evidence.audit.evidenceRetentionStatus; Allowed = @('retained', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'independent review'; Actual = [string]$evidence.audit.independentReviewStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access audit'; Actual = [string]$evidence.audit.accessAuditStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'restore audit'; Actual = [string]$evidence.audit.restoreAuditStatus; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The custody chain audit contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.chainHeadGateReference; Description = 'Chain head gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.chainInventoryReference; Description = 'Chain inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rootCustodyReference; Description = 'Root custody reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.evidenceRetentionReference; Description = 'Evidence retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.independentReviewReference; Description = 'Independent review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessAuditReference; Description = 'Access audit reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreAuditReference; Description = 'Restore audit reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.auditedBy; Description = 'AuditedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entriesDescending = [System.Collections.Generic.List[object]]::new()
$currentPath = $resolvedHeadPath
while ($true) {
    if (-not $visited.Add($currentPath)) {
        throw 'The production assurance custody-review chain contains a cycle.'
    }
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        throw "The production assurance custody-review chain is missing an artifact: $currentPath"
    }
    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $currentType = [string]$current.evidenceType
    if ($currentType -eq 'scheduled-production-assurance-custody-review') {
        $currentSequence = 1
        $currentRootCustody = $current.custodyEvidence
    }
    elseif ($currentType -eq 'recurring-production-assurance-custody-review') {
        $currentSequence = [int]$current.review.sequence
        $currentRootCustody = $current.rootCustodyEvidence
        if ($currentSequence -lt 2 -or [int]$current.review.previousSequence -ne ($currentSequence - 1)) {
            throw 'The recurring production assurance custody-review chain contains a sequence gap.'
        }
    }
    else {
        throw "The production assurance custody-review chain contains unsupported evidence type '$currentType'."
    }
    if (
        [string]$current.productionContext -ne $ExpectedProductionContext -or
        [string]$current.namespace -ne 'shieldward' -or
        [string]$current.outcome -ne 'passed' -or
        [bool]$current.decision.custodyContinuityProven -ne $true -or
        [string]$current.candidate.version -ne [string]$head.candidate.version -or
        [string]$current.candidate.sourceTag -ne [string]$head.candidate.sourceTag -or
        [string]$current.candidate.controlPlaneImage -ne [string]$head.candidate.controlPlaneImage -or
        [string]$current.candidate.edgeImage -ne [string]$head.candidate.edgeImage -or
        [string]$current.candidate.policyVersion -ne [string]$head.candidate.policyVersion
    ) {
        throw 'The custody-review chain changed identity, candidate, or passed state.'
    }
    if (
        [string]$currentRootCustody.relativePath -ne [string]$headRootCustody.relativePath -or
        [string]$currentRootCustody.sha256 -ne [string]$headRootCustody.sha256 -or
        [string]$currentRootCustody.integrityDigest -ne [string]$headRootCustody.integrityDigest -or
        [string]$currentRootCustody.chainDigest -ne [string]$headRootCustody.chainDigest -or
        [int]$currentRootCustody.headReviewSequence -ne [int]$headRootCustody.headReviewSequence -or
        ([DateTimeOffset]$currentRootCustody.retentionUntilUtc).ToUniversalTime().ToString('o') -ne $retentionUntil.ToString('o') -or
        [string]$currentRootCustody.outcome -ne 'passed' -or
        [bool]$currentRootCustody.custodyConfirmed -ne $true
    ) {
        throw 'The custody-review chain changed its root custody identity or retention boundary.'
    }

    $currentRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $currentPath).Replace('\', '/')
    $currentHash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $entriesDescending.Add([ordered]@{
        evidenceType = $currentType
        sequence = $currentSequence
        relativePath = $currentRelativePath
        sha256 = $currentHash
        integrityDigest = [string]$current.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$current.collectedAtUtc).ToUniversalTime().ToString('o')
        completedAtUtc = ([DateTimeOffset]$current.review.completedAtUtc).ToUniversalTime().ToString('o')
        expectedDueAtUtc = if ($currentType -eq 'scheduled-production-assurance-custody-review') {
            ([DateTimeOffset]$current.review.scheduledDueAtUtc).ToUniversalTime().ToString('o')
        }
        else {
            ([DateTimeOffset]$current.review.expectedDueAtUtc).ToUniversalTime().ToString('o')
        }
        nextReviewDueAtUtc = ([DateTimeOffset]$current.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o')
        retentionRemainingDays = [double]$current.retention.remainingDays
        rootCustodySha256 = [string]$currentRootCustody.sha256
        outcome = [string]$current.outcome
    })
    if ($currentType -eq 'scheduled-production-assurance-custody-review') {
        break
    }
    $currentPath = Resolve-LocalStatePath -Path ([string]$current.previousCustodyReviewEvidence.relativePath) -Description 'Recorded previous custody review evidence path'
}

$chainEntries = @($entriesDescending)
[array]::Reverse($chainEntries)
$chainDigest = Get-Sha256Text -Text ($chainEntries | ConvertTo-Json -Depth 5 -Compress)
$storedCanonicalEntries = @($evidence.chain.entries) | ForEach-Object {
    [ordered]@{
        evidenceType = [string]$_.evidenceType
        sequence = [int]$_.sequence
        relativePath = [string]$_.relativePath
        sha256 = [string]$_.sha256
        integrityDigest = [string]$_.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$_.collectedAtUtc).ToUniversalTime().ToString('o')
        completedAtUtc = ([DateTimeOffset]$_.completedAtUtc).ToUniversalTime().ToString('o')
        expectedDueAtUtc = ([DateTimeOffset]$_.expectedDueAtUtc).ToUniversalTime().ToString('o')
        nextReviewDueAtUtc = ([DateTimeOffset]$_.nextReviewDueAtUtc).ToUniversalTime().ToString('o')
        retentionRemainingDays = [double]$_.retentionRemainingDays
        rootCustodySha256 = [string]$_.rootCustodySha256
        outcome = [string]$_.outcome
    }
}
if (
    $chainEntries.Count -ne [int]$head.review.sequence -or
    [bool]$evidence.chain.verified -ne $true -or
    [bool]$evidence.chain.rootCustodyVerified -ne $true -or
    [int]$evidence.chain.firstSequence -ne 1 -or
    [int]$evidence.chain.headSequence -ne [int]$head.review.sequence -or
    [int]$evidence.chain.entryCount -ne $chainEntries.Count -or
    [string]$evidence.chain.digest -ne $chainDigest -or
    ($storedCanonicalEntries | ConvertTo-Json -Depth 5 -Compress) -ne ($chainEntries | ConvertTo-Json -Depth 5 -Compress)
) {
    throw 'The production assurance custody chain inventory, root, digest, or entry count is invalid.'
}
for ($index = 0; $index -lt $chainEntries.Count; $index++) {
    if ([int]$chainEntries[$index].sequence -ne ($index + 1)) {
        throw 'The production assurance custody chain inventory is not contiguous from sequence 1.'
    }
}

$headCollectedAt = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()
$headCompletedAt = ([DateTimeOffset]$head.review.completedAtUtc).ToUniversalTime()
$auditCompletedAt = ([DateTimeOffset]$evidence.audit.completedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$headAgeAtCollection = $collectedAt - $headCollectedAt
$auditAgeAtCollection = $collectedAt - $auditCompletedAt
if (
    $auditCompletedAt -lt $headCompletedAt -or
    $auditCompletedAt -ge $retentionUntil -or
    [int]$evidence.audit.maxHeadEvidenceAgeHours -lt 1 -or
    [int]$evidence.audit.maxHeadEvidenceAgeHours -gt 8760 -or
    $headAgeAtCollection.TotalHours -lt -1 -or
    $headAgeAtCollection.TotalHours -gt [int]$evidence.audit.maxHeadEvidenceAgeHours -or
    [int]$evidence.audit.maxAuditAgeMinutes -lt 5 -or
    [int]$evidence.audit.maxAuditAgeMinutes -gt 1440 -or
    $auditAgeAtCollection.TotalMinutes -lt -5 -or
    $auditAgeAtCollection.TotalMinutes -gt [int]$evidence.audit.maxAuditAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The production assurance custody chain-audit timing, freshness, or retention boundary is invalid.'
}

$hasFailure = (
    [string]$evidence.audit.chainHeadGateStatus -eq 'failed' -or
    [string]$evidence.audit.chainInventoryStatus -eq 'incomplete' -or
    [string]$evidence.audit.rootCustodyStatus -eq 'invalid' -or
    [string]$evidence.audit.evidenceRetentionStatus -eq 'missing' -or
    [string]$evidence.audit.independentReviewStatus -eq 'failed' -or
    [string]$evidence.audit.accessAuditStatus -eq 'failed' -or
    [string]$evidence.audit.restoreAuditStatus -eq 'failed'
)
$hasUnknown = @(
    [string]$evidence.audit.chainHeadGateStatus,
    [string]$evidence.audit.chainInventoryStatus,
    [string]$evidence.audit.rootCustodyStatus,
    [string]$evidence.audit.evidenceRetentionStatus,
    [string]$evidence.audit.independentReviewStatus,
    [string]$evidence.audit.accessAuditStatus,
    [string]$evidence.audit.restoreAuditStatus
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedAuditPassed = $expectedOutcome -eq 'passed'
$expectedNextAction = if ([string]$evidence.audit.chainHeadGateStatus -eq 'failed') {
    'revalidate-custody-review-chain'
}
elseif ([string]$evidence.audit.chainInventoryStatus -eq 'incomplete' -or [string]$evidence.audit.rootCustodyStatus -eq 'invalid') {
    'restore-evidence-and-investigate'
}
elseif ([string]$evidence.audit.evidenceRetentionStatus -eq 'missing') {
    'renew-retention-before-continuing'
}
elseif ([string]$evidence.audit.independentReviewStatus -eq 'failed') {
    'open-custody-governance-incident'
}
elseif ([string]$evidence.audit.accessAuditStatus -eq 'failed') {
    'investigate-evidence-access'
}
elseif ([string]$evidence.audit.restoreAuditStatus -eq 'failed') {
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
    [bool]$evidence.decision.chainVerified -ne $true -or
    [bool]$evidence.decision.rootCustodyVerified -ne $true -or
    [bool]$evidence.decision.auditPassed -ne $expectedAuditPassed -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The production assurance custody chain-audit outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    chainHeadEvidenceSha256 = $headHash
    chainHeadEvidenceIntegrityDigest = [string]$head.integrityDigest
    rootCustodyEvidenceSha256 = [string]$headRootCustody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$headRootCustody.integrityDigest
    rootCustodyChainDigest = [string]$headRootCustody.chainDigest
    rootCustodyRetentionUntilUtc = $retentionUntil.ToString('o')
    chainDigest = $chainDigest
    chainEntryCount = $chainEntries.Count
    firstReviewSequence = 1
    headReviewSequence = [int]$head.review.sequence
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$head.incidentId
    closureChangeId = [string]$head.closureChangeId
    releaseVersion = [string]$head.candidate.version
    sourceTag = [string]$head.candidate.sourceTag
    controlPlaneImage = [string]$head.candidate.controlPlaneImage
    edgeImage = [string]$head.candidate.edgeImage
    policyVersion = [string]$head.candidate.policyVersion
    rootCustodyCollectedAtUtc = $rootCustodyCollectedAt.ToString('o')
    headCollectedAtUtc = $headCollectedAt.ToString('o')
    auditCompletedAtUtc = $auditCompletedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxHeadEvidenceAgeHours = [int]$evidence.audit.maxHeadEvidenceAgeHours
    maxAuditAgeMinutes = [int]$evidence.audit.maxAuditAgeMinutes
    chainHeadGateStatus = [string]$evidence.audit.chainHeadGateStatus
    chainInventoryStatus = [string]$evidence.audit.chainInventoryStatus
    rootCustodyStatus = [string]$evidence.audit.rootCustodyStatus
    evidenceRetentionStatus = [string]$evidence.audit.evidenceRetentionStatus
    independentReviewStatus = [string]$evidence.audit.independentReviewStatus
    accessAuditStatus = [string]$evidence.audit.accessAuditStatus
    restoreAuditStatus = [string]$evidence.audit.restoreAuditStatus
    chainHeadGateReference = [string]$evidence.externalEvidence.chainHeadGateReference
    chainInventoryReference = [string]$evidence.externalEvidence.chainInventoryReference
    rootCustodyReference = [string]$evidence.externalEvidence.rootCustodyReference
    evidenceRetentionReference = [string]$evidence.externalEvidence.evidenceRetentionReference
    independentReviewReference = [string]$evidence.externalEvidence.independentReviewReference
    accessAuditReference = [string]$evidence.externalEvidence.accessAuditReference
    restoreAuditReference = [string]$evidence.externalEvidence.restoreAuditReference
    auditedBy = [string]$evidence.externalEvidence.auditedBy
    chainVerified = $true
    rootCustodyVerified = $true
    auditPassed = $expectedAuditPassed
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance custody chain-audit evidence integrity digest is invalid.'
}

Write-Host "Production assurance custody chain-audit evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Verified custody-review sequences 1 through $($head.review.sequence); entries: $($chainEntries.Count)"
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
