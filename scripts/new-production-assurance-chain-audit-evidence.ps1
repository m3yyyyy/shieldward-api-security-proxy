[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainHeadEvidencePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$AuditCompletedAtUtc,

    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$ChainHeadGateStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$ChainInventoryStatus,
    [Parameter(Mandatory)][ValidateSet('retained', 'missing', 'unknown')][string]$EvidenceRetentionStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$IndependentReviewStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$AccessAuditStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainHeadGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ChainInventoryReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidenceRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$IndependentReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessAuditReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuditedBy,

    [ValidateRange(1, 2160)][int]$MaxHeadEvidenceAgeHours = 168,
    [ValidateRange(5, 1440)][int]$MaxAuditAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-chain-audit',
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
    [pscustomobject]@{ Value = $ChainHeadGateReference; Description = 'ChainHeadGateReference' }
    [pscustomobject]@{ Value = $ChainInventoryReference; Description = 'ChainInventoryReference' }
    [pscustomobject]@{ Value = $EvidenceRetentionReference; Description = 'EvidenceRetentionReference' }
    [pscustomobject]@{ Value = $IndependentReviewReference; Description = 'IndependentReviewReference' }
    [pscustomobject]@{ Value = $AccessAuditReference; Description = 'AccessAuditReference' }
    [pscustomobject]@{ Value = $AuditedBy; Description = 'AuditedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedHeadPath = Resolve-LocalStatePath -Path $ChainHeadEvidencePath -Description 'ChainHeadEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedHeadPath -PathType Leaf)) {
    throw "Production assurance chain head evidence is missing: $resolvedHeadPath"
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
if (
    [string]$head.outcome -ne 'passed' -or
    [int]$head.review.sequence -lt 2 -or
    [bool]$head.decision.continuityLinkValid -ne $true -or
    [bool]$head.decision.continuityProven -ne $true -or
    [string]$head.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'The chain audit requires an exact passed recurring assurance head.'
}

$visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entriesDescending = [System.Collections.Generic.List[object]]::new()
$currentPath = $resolvedHeadPath
while ($true) {
    if (-not $visited.Add($currentPath)) {
        throw 'The production assurance review chain contains a cycle.'
    }
    if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
        throw "The production assurance review chain is missing an artifact: $currentPath"
    }

    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    $currentType = [string]$current.evidenceType
    $currentSequence = [int]$current.review.sequence
    if ($currentType -eq 'scheduled-production-assurance-continuity') {
        if ($currentSequence -ne 1) {
            throw 'The production assurance review chain root must be sequence 1.'
        }
    }
    elseif ($currentType -eq 'recurring-production-assurance-continuity') {
        if (
            $currentSequence -lt 2 -or
            [int]$current.review.previousSequence -ne ($currentSequence - 1)
        ) {
            throw 'The recurring production assurance review chain contains a sequence gap.'
        }
    }
    else {
        throw "The production assurance review chain contains unsupported evidence type '$currentType'."
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
        throw 'The production assurance review chain changed identity, candidate, or passed state.'
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
if ($chainEntries.Count -ne [int]$head.review.sequence) {
    throw 'The production assurance chain count does not match its head sequence.'
}
for ($index = 0; $index -lt $chainEntries.Count; $index++) {
    if ([int]$chainEntries[$index].sequence -ne ($index + 1)) {
        throw 'The production assurance chain inventory is not contiguous from sequence 1.'
    }
}

$auditCompletedAt = $AuditCompletedAtUtc.ToUniversalTime()
$headCollectedAt = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()
$headCompletedAt = ([DateTimeOffset]$head.review.completedAtUtc).ToUniversalTime()
$headAge = $referenceNow - $headCollectedAt
$auditAge = $referenceNow - $auditCompletedAt
if (
    $auditCompletedAt -lt $headCompletedAt -or
    $headAge.TotalHours -lt -1 -or
    $headAge.TotalHours -gt $MaxHeadEvidenceAgeHours -or
    $auditAge.TotalMinutes -lt -5 -or
    $auditAge.TotalMinutes -gt $MaxAuditAgeMinutes
) {
    throw 'The assurance chain audit must follow the chain head and use freshness-bounded evidence.'
}

$hasFailure = (
    $ChainHeadGateStatus -eq 'failed' -or
    $ChainInventoryStatus -eq 'incomplete' -or
    $EvidenceRetentionStatus -eq 'missing' -or
    $IndependentReviewStatus -eq 'failed' -or
    $AccessAuditStatus -eq 'failed'
)
$hasUnknown = @(
    $ChainHeadGateStatus,
    $ChainInventoryStatus,
    $EvidenceRetentionStatus,
    $IndependentReviewStatus,
    $AccessAuditStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$auditPassed = $outcome -eq 'passed'
$nextAction = if ($ChainHeadGateStatus -eq 'failed') {
    'revalidate-assurance-chain'
}
elseif ($ChainInventoryStatus -eq 'incomplete' -or $EvidenceRetentionStatus -eq 'missing') {
    'restore-evidence-and-investigate'
}
elseif ($IndependentReviewStatus -eq 'failed') {
    'open-assurance-governance-incident'
}
elseif ($AccessAuditStatus -eq 'failed') {
    'investigate-evidence-access'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}

$collectedAt = $referenceNow
$headHash = (Get-FileHash -LiteralPath $resolvedHeadPath -Algorithm SHA256).Hash.ToLowerInvariant()
$headRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedHeadPath).Replace('\', '/')
$chainDigest = Get-Sha256Text -Text ($chainEntries | ConvertTo-Json -Depth 5 -Compress)
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
    maxHeadEvidenceAgeHours = $MaxHeadEvidenceAgeHours
    maxAuditAgeMinutes = $MaxAuditAgeMinutes
    chainHeadGateStatus = $ChainHeadGateStatus
    chainInventoryStatus = $ChainInventoryStatus
    evidenceRetentionStatus = $EvidenceRetentionStatus
    independentReviewStatus = $IndependentReviewStatus
    accessAuditStatus = $AccessAuditStatus
    chainHeadGateReference = $ChainHeadGateReference
    chainInventoryReference = $ChainInventoryReference
    evidenceRetentionReference = $EvidenceRetentionReference
    independentReviewReference = $IndependentReviewReference
    accessAuditReference = $AccessAuditReference
    auditedBy = $AuditedBy
    chainVerified = $true
    auditPassed = $auditPassed
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'production-assurance-chain-audit'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$head.incidentId
    closureChangeId = [string]$head.closureChangeId
    candidate = [ordered]@{
        version = [string]$head.candidate.version
        sourceTag = [string]$head.candidate.sourceTag
        controlPlaneImage = [string]$head.candidate.controlPlaneImage
        edgeImage = [string]$head.candidate.edgeImage
        policyVersion = [string]$head.candidate.policyVersion
    }
    chainHeadEvidence = [ordered]@{
        relativePath = $headRelativePath
        sha256 = $headHash
        integrityDigest = [string]$head.integrityDigest
        collectedAtUtc = $headCollectedAt.ToString('o')
        reviewSequence = [int]$head.review.sequence
        outcome = [string]$head.outcome
        continuityProven = [bool]$head.decision.continuityProven
    }
    chain = [ordered]@{
        verified = $true
        firstSequence = 1
        headSequence = [int]$head.review.sequence
        entryCount = $chainEntries.Count
        digest = $chainDigest
        entries = $chainEntries
    }
    audit = [ordered]@{
        completedAtUtc = $auditCompletedAt.ToString('o')
        maxHeadEvidenceAgeHours = $MaxHeadEvidenceAgeHours
        maxAuditAgeMinutes = $MaxAuditAgeMinutes
        chainHeadGateStatus = $ChainHeadGateStatus
        chainInventoryStatus = $ChainInventoryStatus
        evidenceRetentionStatus = $EvidenceRetentionStatus
        independentReviewStatus = $IndependentReviewStatus
        accessAuditStatus = $AccessAuditStatus
    }
    externalEvidence = [ordered]@{
        chainHeadGateReference = $ChainHeadGateReference
        chainInventoryReference = $ChainInventoryReference
        evidenceRetentionReference = $EvidenceRetentionReference
        independentReviewReference = $IndependentReviewReference
        accessAuditReference = $AccessAuditReference
        auditedBy = $AuditedBy
    }
    decision = [ordered]@{
        chainVerified = $true
        auditPassed = $auditPassed
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'chain-audit-{0}-sequence-{1}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), [int]$head.review.sequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance chain audit evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production assurance chain audit evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Verified review sequences 1 through $($head.review.sequence); entries: $($chainEntries.Count); next action: $nextAction"
Write-Host 'No scheduler, cluster, traffic, incident, evidence-retention, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'The assurance chain audit did not pass. Preserve the chain and follow the recorded action.'
}
