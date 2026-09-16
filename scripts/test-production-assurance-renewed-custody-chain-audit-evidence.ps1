[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainHeadEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
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

function Test-JsonEqual {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    return (
        ($Left | ConvertTo-Json -Depth 10 -Compress) -eq
        ($Right | ConvertTo-Json -Depth 10 -Compress)
    )
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
    throw "Renewed production assurance custody chain-audit evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'renewed-production-assurance-custody-chain-audit'
) {
    throw 'The supplied renewed production assurance custody chain-audit evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext -or [string]$evidence.namespace -ne 'shieldward') {
    throw 'The renewed custody chain-audit evidence targets the wrong context or namespace.'
}

$resolvedHeadPath = if ([string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.chainHeadEvidence.relativePath) -Description 'Recorded chain head path'
}
else {
    Resolve-LocalStatePath -Path $ChainHeadEvidencePath -Description 'ChainHeadEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedHeadPath -PathType Leaf)) {
    throw "Recorded renewed custody-review chain head is missing: $resolvedHeadPath"
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
$headHash = (Get-FileHash -LiteralPath $resolvedHeadPath -Algorithm SHA256).Hash.ToLowerInvariant()
$headRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedHeadPath).Replace('\', '/')
$headCollectedAt = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()
if (
    $headRelativePath -ne [string]$evidence.chainHeadEvidence.relativePath -or
    $headHash -ne [string]$evidence.chainHeadEvidence.sha256 -or
    [string]$head.integrityDigest -ne [string]$evidence.chainHeadEvidence.integrityDigest -or
    $headCollectedAt.ToString('o') -ne ([DateTimeOffset]$evidence.chainHeadEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$head.review.sequence -ne [int]$evidence.chainHeadEvidence.reviewSequence -or
    [string]$head.outcome -ne [string]$evidence.chainHeadEvidence.outcome -or
    [bool]$head.decision.custodyContinuityProven -ne [bool]$evidence.chainHeadEvidence.custodyContinuityProven
) {
    throw 'The exact recurring renewed custody-review head no longer matches the audit evidence.'
}
if (
    [string]$head.evidenceType -ne 'recurring-renewed-production-assurance-custody-review' -or
    [string]$head.outcome -ne 'passed' -or
    [bool]$head.decision.baselineLinkValid -ne $true -or
    [bool]$head.decision.predecessorLinkValid -ne $true -or
    [bool]$head.decision.originalLineagePreserved -ne $true -or
    [bool]$head.decision.custodyContinuityProven -ne $true -or
    [string]$head.decision.nextAction -ne 'continue-renewed-custody-reviews'
) {
    throw 'The renewed custody chain-audit head is not an exact passed recurring review.'
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
    $baselineRelativePath -ne [string]$evidence.renewedCustodyBaseline.relativePath -or
    $baselineHash -ne [string]$evidence.renewedCustodyBaseline.sha256 -or
    [string]$baseline.integrityDigest -ne [string]$evidence.renewedCustodyBaseline.integrityDigest -or
    [string]$baseline.renewedBaseline.lineageDigest -ne [string]$evidence.renewedCustodyBaseline.lineageDigest -or
    -not (Test-JsonEqual -Left $evidence.renewedCustodyBaseline -Right $head.renewedCustodyBaseline) -or
    -not (Test-JsonEqual -Left $evidence.renewalEvidence -Right $head.renewalEvidence) -or
    -not (Test-JsonEqual -Left $evidence.originalCustody -Right $head.originalCustody) -or
    -not (Test-JsonEqual -Left $evidence.priorReviewChain -Right $head.priorReviewChain)
) {
    throw 'The renewed custody chain audit changed its baseline, renewal, or original lineage.'
}
if (
    [string]$evidence.changeId -ne [string]$head.changeId -or
    [string]$evidence.incidentId -ne [string]$head.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$head.closureChangeId -or
    -not (Test-JsonEqual -Left $evidence.candidate -Right $head.candidate)
) {
    throw 'The renewed custody chain audit changed the production identity or candidate.'
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
        -not (Test-JsonEqual -Left $current.candidate -Right $head.candidate) -or
        -not (Test-JsonEqual -Left $current.renewedCustodyBaseline -Right $head.renewedCustodyBaseline) -or
        -not (Test-JsonEqual -Left $current.renewalEvidence -Right $head.renewalEvidence) -or
        -not (Test-JsonEqual -Left $current.originalCustody -Right $head.originalCustody) -or
        -not (Test-JsonEqual -Left $current.priorReviewChain -Right $head.priorReviewChain) -or
        ([DateTimeOffset]$current.retention.untilUtc).ToUniversalTime().ToString('o') -ne $retentionUntil.ToString('o')
    ) {
        throw 'The renewed custody-review chain changed identity, lineage, retention, or passed state.'
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
$chainDigest = Get-Sha256Text -Text ($chainEntries | ConvertTo-Json -Depth 5 -Compress)
if (
    [bool]$evidence.chain.verified -ne $true -or
    [bool]$evidence.chain.baselineVerified -ne $true -or
    [bool]$evidence.chain.renewalVerified -ne $true -or
    [bool]$evidence.chain.originalLineageVerified -ne $true -or
    [int]$evidence.chain.initialSequence -ne $initialSequence -or
    [int]$evidence.chain.headSequence -ne [int]$head.review.sequence -or
    [int]$evidence.chain.entryCount -ne $chainEntries.Count
) {
    throw 'The renewed custody-review chain inventory range or verification flags are invalid.'
}
if ([string]$evidence.chain.digest -ne $chainDigest) {
    throw 'The renewed custody-review chain aggregate digest is invalid.'
}
for ($index = 0; $index -lt $chainEntries.Count; $index++) {
    $recordedEntry = $evidence.chain.entries[$index]
    $expectedEntry = $chainEntries[$index]
    if (
        [string]$recordedEntry.evidenceType -ne [string]$expectedEntry.evidenceType -or
        [int]$recordedEntry.sequence -ne [int]$expectedEntry.sequence -or
        [string]$recordedEntry.relativePath -ne [string]$expectedEntry.relativePath -or
        [string]$recordedEntry.sha256 -ne [string]$expectedEntry.sha256 -or
        [string]$recordedEntry.integrityDigest -ne [string]$expectedEntry.integrityDigest -or
        [string]$recordedEntry.linkDigest -ne [string]$expectedEntry.linkDigest -or
        ([DateTimeOffset]$recordedEntry.collectedAtUtc).ToUniversalTime().ToString('o') -ne
            ([DateTimeOffset]$expectedEntry.collectedAtUtc).ToUniversalTime().ToString('o') -or
        ([DateTimeOffset]$recordedEntry.completedAtUtc).ToUniversalTime().ToString('o') -ne
            ([DateTimeOffset]$expectedEntry.completedAtUtc).ToUniversalTime().ToString('o') -or
        ([DateTimeOffset]$recordedEntry.expectedDueAtUtc).ToUniversalTime().ToString('o') -ne
            ([DateTimeOffset]$expectedEntry.expectedDueAtUtc).ToUniversalTime().ToString('o') -or
        ([DateTimeOffset]$recordedEntry.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne
            ([DateTimeOffset]$expectedEntry.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -or
        [string]$recordedEntry.outcome -ne [string]$expectedEntry.outcome
    ) {
        throw "The renewed custody-review chain inventory entry at index $index is invalid."
    }
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'chain head gate'; Actual = [string]$evidence.audit.chainHeadGateStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'renewed chain inventory'; Actual = [string]$evidence.audit.renewedChainInventoryStatus; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'baseline'; Actual = [string]$evidence.audit.baselineStatus; Allowed = @('verified', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'renewal evidence'; Actual = [string]$evidence.audit.renewalEvidenceStatus; Allowed = @('verified', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'original lineage'; Actual = [string]$evidence.audit.originalLineageStatus; Allowed = @('preserved', 'changed', 'unknown') }
    [pscustomobject]@{ Name = 'evidence retention'; Actual = [string]$evidence.audit.evidenceRetentionStatus; Allowed = @('retained', 'at-risk', 'unknown') }
    [pscustomobject]@{ Name = 'independent review'; Actual = [string]$evidence.audit.independentReviewStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access audit'; Actual = [string]$evidence.audit.accessAuditStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'restore audit'; Actual = [string]$evidence.audit.restoreAuditStatus; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The renewed custody chain audit contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.chainHeadGateReference; Description = 'Chain head gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.renewedChainInventoryReference; Description = 'Renewed chain inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.baselineReference; Description = 'Baseline reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.renewalEvidenceReference; Description = 'Renewal evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.originalLineageReference; Description = 'Original lineage reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.evidenceRetentionReference; Description = 'Evidence retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.independentReviewReference; Description = 'Independent review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessAuditReference; Description = 'Access audit reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreAuditReference; Description = 'Restore audit reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.auditedBy; Description = 'Audited by' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$auditCompletedAt = ([DateTimeOffset]$evidence.audit.completedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$headCompletedAt = ([DateTimeOffset]$head.review.completedAtUtc).ToUniversalTime()
$recordedRetentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
$recordedNextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$headAgeAtCollection = $collectedAt - $headCollectedAt
$auditAgeAtCollection = $collectedAt - $auditCompletedAt
if (
    $recordedRetentionUntil.ToString('o') -ne $retentionUntil.ToString('o') -or
    $recordedNextReviewDueAt.ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne [bool]$head.schedule.nextReviewWithinRetention -or
    [double]$evidence.retention.remainingDays -ne [double]$head.retention.remainingDays -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne [bool]$head.retention.remainingMeetsPolicy -or
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
    throw 'The renewed custody chain-audit timing, schedule, retention, or freshness boundary is invalid.'
}

$hasFailure = (
    [string]$evidence.audit.chainHeadGateStatus -eq 'failed' -or
    [string]$evidence.audit.renewedChainInventoryStatus -eq 'incomplete' -or
    [string]$evidence.audit.baselineStatus -eq 'missing' -or
    [string]$evidence.audit.renewalEvidenceStatus -eq 'missing' -or
    [string]$evidence.audit.originalLineageStatus -eq 'changed' -or
    [string]$evidence.audit.evidenceRetentionStatus -eq 'at-risk' -or
    [string]$evidence.audit.independentReviewStatus -eq 'failed' -or
    [string]$evidence.audit.accessAuditStatus -eq 'failed' -or
    [string]$evidence.audit.restoreAuditStatus -eq 'failed'
)
$hasUnknown = @(
    [string]$evidence.audit.chainHeadGateStatus,
    [string]$evidence.audit.renewedChainInventoryStatus,
    [string]$evidence.audit.baselineStatus,
    [string]$evidence.audit.renewalEvidenceStatus,
    [string]$evidence.audit.originalLineageStatus,
    [string]$evidence.audit.evidenceRetentionStatus,
    [string]$evidence.audit.independentReviewStatus,
    [string]$evidence.audit.accessAuditStatus,
    [string]$evidence.audit.restoreAuditStatus
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedAuditPassed = $expectedOutcome -eq 'passed'
$expectedNextAction = if (
    [string]$evidence.audit.renewedChainInventoryStatus -eq 'incomplete' -or
    [string]$evidence.audit.baselineStatus -eq 'missing' -or
    [string]$evidence.audit.renewalEvidenceStatus -eq 'missing'
) {
    'restore-evidence-and-investigate'
}
elseif ([string]$evidence.audit.originalLineageStatus -eq 'changed') {
    'preserve-chain-and-investigate'
}
elseif ([string]$evidence.audit.evidenceRetentionStatus -eq 'at-risk') {
    'renew-retention-before-continuing'
}
elseif ([string]$evidence.audit.accessAuditStatus -eq 'failed') {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.audit.restoreAuditStatus -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif (
    [string]$evidence.audit.chainHeadGateStatus -eq 'failed' -or
    [string]$evidence.audit.independentReviewStatus -eq 'failed'
) {
    'stop-and-investigate-renewed-custody-chain'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-renewed-custody-reviews'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.chainVerified -ne $true -or
    [bool]$evidence.decision.baselineVerified -ne $true -or
    [bool]$evidence.decision.renewalVerified -ne $true -or
    [bool]$evidence.decision.originalLineageVerified -ne $true -or
    [bool]$evidence.decision.auditPassed -ne $expectedAuditPassed -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The renewed custody chain-audit outcome or action is inconsistent with recorded evidence.'
}

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
    maxHeadEvidenceAgeHours = [int]$evidence.audit.maxHeadEvidenceAgeHours
    maxAuditAgeMinutes = [int]$evidence.audit.maxAuditAgeMinutes
    chainHeadGateStatus = [string]$evidence.audit.chainHeadGateStatus
    renewedChainInventoryStatus = [string]$evidence.audit.renewedChainInventoryStatus
    baselineStatus = [string]$evidence.audit.baselineStatus
    renewalEvidenceStatus = [string]$evidence.audit.renewalEvidenceStatus
    originalLineageStatus = [string]$evidence.audit.originalLineageStatus
    evidenceRetentionStatus = [string]$evidence.audit.evidenceRetentionStatus
    independentReviewStatus = [string]$evidence.audit.independentReviewStatus
    accessAuditStatus = [string]$evidence.audit.accessAuditStatus
    restoreAuditStatus = [string]$evidence.audit.restoreAuditStatus
    chainHeadGateReference = [string]$evidence.externalEvidence.chainHeadGateReference
    renewedChainInventoryReference = [string]$evidence.externalEvidence.renewedChainInventoryReference
    baselineReference = [string]$evidence.externalEvidence.baselineReference
    renewalEvidenceReference = [string]$evidence.externalEvidence.renewalEvidenceReference
    originalLineageReference = [string]$evidence.externalEvidence.originalLineageReference
    evidenceRetentionReference = [string]$evidence.externalEvidence.evidenceRetentionReference
    independentReviewReference = [string]$evidence.externalEvidence.independentReviewReference
    accessAuditReference = [string]$evidence.externalEvidence.accessAuditReference
    restoreAuditReference = [string]$evidence.externalEvidence.restoreAuditReference
    auditedBy = [string]$evidence.externalEvidence.auditedBy
    chainVerified = $true
    baselineVerified = $true
    renewalVerified = $true
    originalLineageVerified = $true
    auditPassed = $expectedAuditPassed
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The renewed production assurance custody chain-audit integrity digest is invalid.'
}

Write-Host "Renewed production assurance custody chain-audit validation passed with outcome '$expectedOutcome'."
Write-Host "Verified renewed review sequences $initialSequence through $($head.review.sequence); entries: $($chainEntries.Count)."
Write-Host 'This validator is read-only and does not schedule reviews, alter archives, change production, or remove evidence.'
