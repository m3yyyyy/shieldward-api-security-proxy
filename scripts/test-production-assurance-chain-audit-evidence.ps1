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
    throw "Production assurance chain audit evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'production-assurance-chain-audit'
) {
    throw 'The supplied production assurance chain audit evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The assurance chain audit targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The assurance chain audit uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedHeadPath = if ([string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.chainHeadEvidence.relativePath) -Description 'Recorded chain head evidence path'
}
else {
    Resolve-LocalStatePath -Path $ChainHeadEvidencePath -Description 'ChainHeadEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedHeadPath -PathType Leaf)) {
    throw "Recorded production assurance chain head evidence is missing: $resolvedHeadPath"
}
$headValidationArguments = @{
    EvidencePath = $resolvedHeadPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $headValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') @headValidationArguments 6>$null

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
    [bool]$evidence.chainHeadEvidence.continuityProven -ne $true
) {
    throw 'The exact passed production assurance chain head no longer matches the audit evidence.'
}
if (
    [string]$head.outcome -ne 'passed' -or
    [int]$head.review.sequence -lt 2 -or
    [bool]$head.decision.continuityLinkValid -ne $true -or
    [bool]$head.decision.continuityProven -ne $true -or
    [string]$head.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'The assurance chain audit requires a passed recurring assurance head.'
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
    throw 'The assurance chain audit identity or candidate does not match its head.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'chain head gate'; Actual = [string]$evidence.audit.chainHeadGateStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'chain inventory'; Actual = [string]$evidence.audit.chainInventoryStatus; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'evidence retention'; Actual = [string]$evidence.audit.evidenceRetentionStatus; Allowed = @('retained', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'independent review'; Actual = [string]$evidence.audit.independentReviewStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access audit'; Actual = [string]$evidence.audit.accessAuditStatus; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The assurance chain audit contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.chainHeadGateReference; Description = 'Chain head gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.chainInventoryReference; Description = 'Chain inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.evidenceRetentionReference; Description = 'Evidence retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.independentReviewReference; Description = 'Independent review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessAuditReference; Description = 'Access audit reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.auditedBy; Description = 'AuditedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entriesDescending = [System.Collections.Generic.List[object]]::new()
$currentPath = $resolvedHeadPath
while ($true) {
    if (-not $visited.Add($currentPath)) {
        throw 'The recorded production assurance review chain contains a cycle.'
    }
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        throw "The recorded production assurance review chain is missing an artifact: $currentPath"
    }
    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $currentType = [string]$current.evidenceType
    $currentSequence = [int]$current.review.sequence
    if ($currentType -eq 'scheduled-production-assurance-continuity') {
        if ($currentSequence -ne 1) {
            throw 'The recorded assurance review chain root is not sequence 1.'
        }
    }
    elseif ($currentType -eq 'recurring-production-assurance-continuity') {
        if ($currentSequence -lt 2 -or [int]$current.review.previousSequence -ne ($currentSequence - 1)) {
            throw 'The recorded recurring assurance chain contains a sequence gap.'
        }
    }
    else {
        throw "The recorded assurance review chain contains unsupported evidence type '$currentType'."
    }
    if (
        [string]$current.productionContext -ne $ExpectedProductionContext -or
        [string]$current.namespace -ne 'shieldward' -or
        [string]$current.outcome -ne 'passed' -or
        [bool]$current.decision.continuityProven -ne $true -or
        [string]$current.candidate.version -ne [string]$head.candidate.version -or
        [string]$current.candidate.sourceTag -ne [string]$head.candidate.sourceTag -or
        [string]$current.candidate.controlPlaneImage -ne [string]$head.candidate.controlPlaneImage -or
        [string]$current.candidate.edgeImage -ne [string]$head.candidate.edgeImage -or
        [string]$current.candidate.policyVersion -ne [string]$head.candidate.policyVersion
    ) {
        throw 'The recorded assurance chain changed identity, candidate, or passed state.'
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
        expectedDueAtUtc = ([DateTimeOffset]$current.review.expectedDueAtUtc).ToUniversalTime().ToString('o')
        nextReviewDueAtUtc = ([DateTimeOffset]$current.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o')
        outcome = [string]$current.outcome
    })
    if ($currentType -eq 'scheduled-production-assurance-continuity') {
        break
    }
    $currentPath = Resolve-LocalStatePath -Path ([string]$current.previousContinuityEvidence.relativePath) -Description 'Recorded previous continuity evidence path'
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
        outcome = [string]$_.outcome
    }
}
$storedEntriesJson = $storedCanonicalEntries | ConvertTo-Json -Depth 5 -Compress
$expectedEntriesJson = $chainEntries | ConvertTo-Json -Depth 5 -Compress
if (
    $chainEntries.Count -ne [int]$head.review.sequence -or
    [bool]$evidence.chain.verified -ne $true -or
    [int]$evidence.chain.firstSequence -ne 1 -or
    [int]$evidence.chain.headSequence -ne [int]$head.review.sequence -or
    [int]$evidence.chain.entryCount -ne $chainEntries.Count -or
    [string]$evidence.chain.digest -ne $chainDigest -or
    $storedEntriesJson -ne $expectedEntriesJson
) {
    throw 'The production assurance chain inventory, digest, or entry count is invalid.'
}
for ($index = 0; $index -lt $chainEntries.Count; $index++) {
    if ([int]$chainEntries[$index].sequence -ne ($index + 1)) {
        throw 'The production assurance chain inventory is not contiguous from sequence 1.'
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
    [int]$evidence.audit.maxHeadEvidenceAgeHours -lt 1 -or
    [int]$evidence.audit.maxHeadEvidenceAgeHours -gt 2160 -or
    $headAgeAtCollection.TotalHours -lt -1 -or
    $headAgeAtCollection.TotalHours -gt [int]$evidence.audit.maxHeadEvidenceAgeHours -or
    [int]$evidence.audit.maxAuditAgeMinutes -lt 5 -or
    [int]$evidence.audit.maxAuditAgeMinutes -gt 1440 -or
    $auditAgeAtCollection.TotalMinutes -lt -5 -or
    $auditAgeAtCollection.TotalMinutes -gt [int]$evidence.audit.maxAuditAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The production assurance chain audit timing or freshness boundary is invalid.'
}

$hasFailure = (
    [string]$evidence.audit.chainHeadGateStatus -eq 'failed' -or
    [string]$evidence.audit.chainInventoryStatus -eq 'incomplete' -or
    [string]$evidence.audit.evidenceRetentionStatus -eq 'missing' -or
    [string]$evidence.audit.independentReviewStatus -eq 'failed' -or
    [string]$evidence.audit.accessAuditStatus -eq 'failed'
)
$hasUnknown = @(
    [string]$evidence.audit.chainHeadGateStatus,
    [string]$evidence.audit.chainInventoryStatus,
    [string]$evidence.audit.evidenceRetentionStatus,
    [string]$evidence.audit.independentReviewStatus,
    [string]$evidence.audit.accessAuditStatus
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedAuditPassed = $expectedOutcome -eq 'passed'
$expectedNextAction = if ([string]$evidence.audit.chainHeadGateStatus -eq 'failed') {
    'revalidate-assurance-chain'
}
elseif (
    [string]$evidence.audit.chainInventoryStatus -eq 'incomplete' -or
    [string]$evidence.audit.evidenceRetentionStatus -eq 'missing'
) {
    'restore-evidence-and-investigate'
}
elseif ([string]$evidence.audit.independentReviewStatus -eq 'failed') {
    'open-assurance-governance-incident'
}
elseif ([string]$evidence.audit.accessAuditStatus -eq 'failed') {
    'investigate-evidence-access'
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
    [bool]$evidence.decision.auditPassed -ne $expectedAuditPassed -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The production assurance chain audit outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    chainHeadEvidenceSha256 = $headHash
    chainHeadEvidenceIntegrityDigest = [string]$head.integrityDigest
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
    headCollectedAtUtc = $headCollectedAt.ToString('o')
    auditCompletedAtUtc = $auditCompletedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxHeadEvidenceAgeHours = [int]$evidence.audit.maxHeadEvidenceAgeHours
    maxAuditAgeMinutes = [int]$evidence.audit.maxAuditAgeMinutes
    chainHeadGateStatus = [string]$evidence.audit.chainHeadGateStatus
    chainInventoryStatus = [string]$evidence.audit.chainInventoryStatus
    evidenceRetentionStatus = [string]$evidence.audit.evidenceRetentionStatus
    independentReviewStatus = [string]$evidence.audit.independentReviewStatus
    accessAuditStatus = [string]$evidence.audit.accessAuditStatus
    chainHeadGateReference = [string]$evidence.externalEvidence.chainHeadGateReference
    chainInventoryReference = [string]$evidence.externalEvidence.chainInventoryReference
    evidenceRetentionReference = [string]$evidence.externalEvidence.evidenceRetentionReference
    independentReviewReference = [string]$evidence.externalEvidence.independentReviewReference
    accessAuditReference = [string]$evidence.externalEvidence.accessAuditReference
    auditedBy = [string]$evidence.externalEvidence.auditedBy
    chainVerified = $true
    auditPassed = $expectedAuditPassed
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance chain audit evidence integrity digest is invalid.'
}

Write-Host "Production assurance chain audit evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Verified contiguous review sequences 1 through $($head.review.sequence); entries: $($chainEntries.Count)"
Write-Host 'This validator is read-only and does not schedule reviews, retain evidence, change production, or remove rollback.'
