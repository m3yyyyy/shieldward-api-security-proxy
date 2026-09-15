[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BaselinePath,
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedBaselinePath = Resolve-LocalStatePath -Path $BaselinePath -Description 'BaselinePath'
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Production assurance renewed custody-review baseline is missing: $resolvedBaselinePath"
}
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json
if (
    [int]$baseline.schemaVersion -ne 1 -or
    [string]$baseline.environment -ne 'production' -or
    [string]$baseline.evidenceType -ne 'production-assurance-renewed-custody-baseline'
) {
    throw 'The supplied production assurance renewed custody-review baseline is unsupported.'
}
if ([string]$baseline.productionContext -ne $ExpectedProductionContext -or [string]$baseline.namespace -ne 'shieldward') {
    throw 'The renewed custody-review baseline targets the wrong context or namespace.'
}

$resolvedRenewalEvidencePath = if ([string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$baseline.renewalEvidence.relativePath) -Description 'Recorded renewal evidence path'
}
else {
    Resolve-LocalStatePath -Path $RenewalEvidencePath -Description 'RenewalEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedRenewalEvidencePath -PathType Leaf)) {
    throw "Recorded production assurance retention-renewal evidence is missing: $resolvedRenewalEvidencePath"
}
$renewalValidationArguments = @{
    EvidencePath = $resolvedRenewalEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $renewalValidationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $renewalValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-evidence.ps1') @renewalValidationArguments 6>$null

$renewal = Get-Content -Raw -LiteralPath $resolvedRenewalEvidencePath | ConvertFrom-Json
$renewalHash = (Get-FileHash -LiteralPath $resolvedRenewalEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$renewalRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedRenewalEvidencePath).Replace('\', '/')
$renewalCollectedAt = ([DateTimeOffset]$renewal.collectedAtUtc).ToUniversalTime()
$renewalCompletedAt = ([DateTimeOffset]$renewal.execution.completedAtUtc).ToUniversalTime()
if (
    $renewalRelativePath -ne [string]$baseline.renewalEvidence.relativePath -or
    $renewalHash -ne [string]$baseline.renewalEvidence.sha256 -or
    [string]$renewal.integrityDigest -ne [string]$baseline.renewalEvidence.integrityDigest -or
    $renewalCollectedAt.ToString('o') -ne ([DateTimeOffset]$baseline.renewalEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    $renewalCompletedAt.ToString('o') -ne ([DateTimeOffset]$baseline.renewalEvidence.executionCompletedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$baseline.renewalEvidence.outcome -ne 'passed' -or
    [bool]$baseline.renewalEvidence.retentionRenewalProven -ne $true -or
    [string]$renewal.outcome -ne 'passed' -or
    [bool]$renewal.decision.retentionRenewalProven -ne $true -or
    [string]$renewal.decision.nextAction -ne 'establish-renewed-custody-review-baseline'
) {
    throw 'The exact passed retention-renewal evidence no longer matches the renewed custody-review baseline.'
}

if (
    [string]$baseline.changeId -ne [string]$renewal.changeId -or
    [string]$baseline.incidentId -ne [string]$renewal.incidentId -or
    [string]$baseline.closureChangeId -ne [string]$renewal.closureChangeId -or
    [string]$baseline.candidate.version -ne [string]$renewal.candidate.version -or
    [string]$baseline.candidate.sourceTag -ne [string]$renewal.candidate.sourceTag -or
    [string]$baseline.candidate.controlPlaneImage -ne [string]$renewal.candidate.controlPlaneImage -or
    [string]$baseline.candidate.edgeImage -ne [string]$renewal.candidate.edgeImage -or
    [string]$baseline.candidate.policyVersion -ne [string]$renewal.candidate.policyVersion
) {
    throw 'The renewed custody-review baseline changed the production identity or candidate.'
}

$priorRetentionUntil = ([DateTimeOffset]$renewal.rootCustody.currentRetentionUntilUtc).ToUniversalTime()
$renewedRetentionUntil = ([DateTimeOffset]$renewal.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$renewal.renewal.nextReviewDueAtUtc).ToUniversalTime()
$previousHeadSequence = [int]$renewal.rootCustody.headReviewSequence
$nextReviewSequence = $previousHeadSequence + 1
if (
    [string]$baseline.originalCustody.relativePath -ne [string]$renewal.rootCustody.relativePath -or
    [string]$baseline.originalCustody.sha256 -ne [string]$renewal.rootCustody.sha256 -or
    [string]$baseline.originalCustody.integrityDigest -ne [string]$renewal.rootCustody.integrityDigest -or
    [string]$baseline.originalCustody.chainDigest -ne [string]$renewal.rootCustody.chainDigest -or
    ([DateTimeOffset]$baseline.originalCustody.priorRetentionUntilUtc).ToUniversalTime().ToString('o') -ne $priorRetentionUntil.ToString('o') -or
    [string]$baseline.priorReviewChain.digest -ne [string]$renewal.rootCustody.reviewChainDigest -or
    [int]$baseline.priorReviewChain.headSequence -ne $previousHeadSequence
) {
    throw 'The renewed custody-review baseline rewrote the original custody or prior review-chain identity.'
}

foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$baseline.renewedBaseline.baselineReference; Description = 'Baseline reference' }
    [pscustomobject]@{ Value = [string]$baseline.operators.establishedBy; Description = 'Established by' }
    [pscustomobject]@{ Value = [string]$baseline.operators.verifiedBy; Description = 'Verified by' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$baselineEstablishedAt = ([DateTimeOffset]$baseline.renewedBaseline.establishedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime()
$renewalAgeAtEstablishment = $baselineEstablishedAt - $renewalCollectedAt
$baselineAgeAtCollection = $collectedAt - $baselineEstablishedAt
if (
    $renewedRetentionUntil -le $priorRetentionUntil -or
    ([DateTimeOffset]$baseline.renewedBaseline.renewedRetentionUntilUtc).ToUniversalTime().ToString('o') -ne $renewedRetentionUntil.ToString('o') -or
    ([DateTimeOffset]$baseline.renewedBaseline.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [int]$baseline.renewedBaseline.generation -ne 2 -or
    [int]$baseline.renewedBaseline.renewalSequence -ne 1 -or
    [int]$baseline.renewedBaseline.previousHeadReviewSequence -ne $previousHeadSequence -or
    [int]$baseline.renewedBaseline.nextReviewSequence -ne $nextReviewSequence -or
    $baselineEstablishedAt -lt $renewalCollectedAt -or
    $baselineEstablishedAt -lt $renewalCompletedAt -or
    $baselineEstablishedAt -ge $nextReviewDueAt -or
    $baselineEstablishedAt -ge $renewedRetentionUntil -or
    [int]$baseline.freshness.maxRenewalEvidenceAgeMinutes -lt 5 -or
    [int]$baseline.freshness.maxRenewalEvidenceAgeMinutes -gt 1440 -or
    $renewalAgeAtEstablishment.TotalMinutes -lt -5 -or
    $renewalAgeAtEstablishment.TotalMinutes -gt [int]$baseline.freshness.maxRenewalEvidenceAgeMinutes -or
    [int]$baseline.freshness.maxBaselineEstablishmentAgeMinutes -lt 5 -or
    [int]$baseline.freshness.maxBaselineEstablishmentAgeMinutes -gt 1440 -or
    $baselineAgeAtCollection.TotalMinutes -lt -5 -or
    $baselineAgeAtCollection.TotalMinutes -gt [int]$baseline.freshness.maxBaselineEstablishmentAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The renewed custody-review baseline timing, sequence, or retention boundary is invalid.'
}

$lineage = [ordered]@{
    rootCustodyEvidenceSha256 = [string]$renewal.rootCustody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$renewal.rootCustody.integrityDigest
    rootCustodyChainDigest = [string]$renewal.rootCustody.chainDigest
    priorReviewChainDigest = [string]$renewal.rootCustody.reviewChainDigest
    previousHeadReviewSequence = $previousHeadSequence
    renewalEvidenceSha256 = $renewalHash
    renewalEvidenceIntegrityDigest = [string]$renewal.integrityDigest
    priorRetentionUntilUtc = $priorRetentionUntil.ToString('o')
    renewedRetentionUntilUtc = $renewedRetentionUntil.ToString('o')
    nextReviewSequence = $nextReviewSequence
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
}
$renewedLineageDigest = Get-Sha256Text -Text ($lineage | ConvertTo-Json -Depth 4 -Compress)
if ([string]$baseline.renewedBaseline.lineageDigest -ne $renewedLineageDigest) {
    throw 'The renewed custody-review lineage digest is invalid.'
}

if (
    [string]$baseline.outcome -ne 'passed' -or
    [bool]$baseline.decision.renewalEvidenceVerified -ne $true -or
    [bool]$baseline.decision.originalCustodyPreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [bool]$baseline.decision.baselineEstablished -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-scheduled-custody-reviews'
) {
    throw 'The renewed custody-review baseline decision is not safe to resume scheduled reviews.'
}

$integrity = [ordered]@{
    renewalEvidenceSha256 = $renewalHash
    renewalEvidenceIntegrityDigest = [string]$renewal.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$renewal.changeId
    incidentId = [string]$renewal.incidentId
    closureChangeId = [string]$renewal.closureChangeId
    releaseVersion = [string]$renewal.candidate.version
    sourceTag = [string]$renewal.candidate.sourceTag
    controlPlaneImage = [string]$renewal.candidate.controlPlaneImage
    edgeImage = [string]$renewal.candidate.edgeImage
    policyVersion = [string]$renewal.candidate.policyVersion
    rootCustodyEvidenceSha256 = [string]$renewal.rootCustody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$renewal.rootCustody.integrityDigest
    rootCustodyChainDigest = [string]$renewal.rootCustody.chainDigest
    priorReviewChainDigest = [string]$renewal.rootCustody.reviewChainDigest
    previousHeadReviewSequence = $previousHeadSequence
    nextReviewSequence = $nextReviewSequence
    priorRetentionUntilUtc = $priorRetentionUntil.ToString('o')
    renewedRetentionUntilUtc = $renewedRetentionUntil.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    baselineGeneration = 2
    renewalSequence = 1
    baselineEstablishedAtUtc = $baselineEstablishedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxRenewalEvidenceAgeMinutes = [int]$baseline.freshness.maxRenewalEvidenceAgeMinutes
    maxBaselineEstablishmentAgeMinutes = [int]$baseline.freshness.maxBaselineEstablishmentAgeMinutes
    baselineReference = [string]$baseline.renewedBaseline.baselineReference
    establishedBy = [string]$baseline.operators.establishedBy
    verifiedBy = [string]$baseline.operators.verifiedBy
    renewedLineageDigest = $renewedLineageDigest
    renewalEvidenceVerified = $true
    originalCustodyPreserved = $true
    priorReviewChainPreserved = $true
    baselineEstablished = $true
    outcome = 'passed'
    nextAction = 'resume-scheduled-custody-reviews'
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$baseline.integrityDigest) {
    throw 'The production assurance renewed custody-review baseline integrity digest is invalid.'
}

Write-Host "Production assurance renewed custody-review baseline validation passed for change $($baseline.changeId)."
Write-Host "Original review head $previousHeadSequence is preserved; next review sequence $nextReviewSequence remains due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This validator is read-only and does not schedule reviews, rewrite evidence, or change archives, retention, cluster, traffic, or rollback.'
