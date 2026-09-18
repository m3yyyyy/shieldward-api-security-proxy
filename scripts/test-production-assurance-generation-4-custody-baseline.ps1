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

function Test-JsonEqual {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)
    return (($Left | ConvertTo-Json -Depth 9 -Compress) -eq ($Right | ConvertTo-Json -Depth 9 -Compress))
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
    throw "Generation-4 custody baseline is missing: $resolvedBaselinePath"
}
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json
if (
    [int]$baseline.schemaVersion -ne 1 -or
    [string]$baseline.environment -ne 'production' -or
    [string]$baseline.evidenceType -ne 'production-assurance-generation-4-custody-baseline'
) {
    throw 'The supplied generation-4 custody baseline is unsupported.'
}
if ([string]$baseline.productionContext -ne $ExpectedProductionContext -or [string]$baseline.namespace -ne 'shieldward') {
    throw 'The generation-4 custody baseline targets the wrong context or namespace.'
}

$resolvedRenewalEvidencePath = if ([string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$baseline.renewalEvidence.relativePath) -Description 'Recorded renewal evidence path'
}
else {
    Resolve-LocalStatePath -Path $RenewalEvidencePath -Description 'RenewalEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedRenewalEvidencePath -PathType Leaf)) {
    throw "Recorded renewed retention-renewal evidence is missing: $resolvedRenewalEvidencePath"
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
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-retention-renewal-evidence.ps1') @renewalValidationArguments 6>$null

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
    [bool]$renewal.decision.lineagePreserved -ne $true -or
    [bool]$renewal.decision.retentionRenewalProven -ne $true -or
    [string]$renewal.decision.nextAction -ne 'establish-generation-4-custody-review-baseline'
) {
    throw 'The exact passed next-renewed retention-renewal evidence no longer matches the generation-4 custody baseline.'
}

if (
    [string]$baseline.changeId -ne [string]$renewal.changeId -or
    [string]$baseline.incidentId -ne [string]$renewal.incidentId -or
    [string]$baseline.closureChangeId -ne [string]$renewal.closureChangeId -or
    -not (Test-JsonEqual -Left $baseline.candidate -Right $renewal.candidate) -or
    -not (Test-JsonEqual -Left $baseline.inheritedLineage -Right $renewal.lineage)
) {
    throw 'The generation-4 custody baseline changed the production identity or inherited lineage.'
}

foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$baseline.generation4Baseline.baselineReference; Description = 'Baseline reference' }
    [pscustomobject]@{ Value = [string]$baseline.operators.establishedBy; Description = 'Established by' }
    [pscustomobject]@{ Value = [string]$baseline.operators.verifiedBy; Description = 'Verified by' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$previousRetentionUntil = ([DateTimeOffset]$renewal.renewal.currentRetentionUntilUtc).ToUniversalTime()
$renewedRetentionUntil = ([DateTimeOffset]$renewal.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$renewal.renewal.nextReviewDueAtUtc).ToUniversalTime()
$previousBaselineGeneration = [int]$renewal.renewal.currentBaselineGeneration
$baselineGeneration = [int]$renewal.renewal.nextBaselineGeneration
$previousRenewalSequence = [int]$renewal.renewal.currentRenewalSequence
$renewalSequence = [int]$renewal.renewal.renewalSequence
$previousHeadReviewSequence = [int]$renewal.lineage.nextRenewedReviewHeadSequence
$nextReviewSequence = $previousHeadReviewSequence + 1
$baselineEstablishedAt = ([DateTimeOffset]$baseline.generation4Baseline.establishedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime()
$renewalAgeAtEstablishment = $baselineEstablishedAt - $renewalCollectedAt
$baselineAgeAtCollection = $collectedAt - $baselineEstablishedAt
if (
    $baselineGeneration -ne ($previousBaselineGeneration + 1) -or
    $renewalSequence -ne ($previousRenewalSequence + 1) -or
    $renewedRetentionUntil -le $previousRetentionUntil -or
    [int]$baseline.generation4Baseline.previousGeneration -ne $previousBaselineGeneration -or
    [int]$baseline.generation4Baseline.generation -ne $baselineGeneration -or
    [int]$baseline.generation4Baseline.previousRenewalSequence -ne $previousRenewalSequence -or
    [int]$baseline.generation4Baseline.renewalSequence -ne $renewalSequence -or
    [int]$baseline.generation4Baseline.previousHeadReviewSequence -ne $previousHeadReviewSequence -or
    [int]$baseline.generation4Baseline.nextReviewSequence -ne $nextReviewSequence -or
    ([DateTimeOffset]$baseline.generation4Baseline.previousRetentionUntilUtc).ToUniversalTime().ToString('o') -ne $previousRetentionUntil.ToString('o') -or
    ([DateTimeOffset]$baseline.generation4Baseline.renewedRetentionUntilUtc).ToUniversalTime().ToString('o') -ne $renewedRetentionUntil.ToString('o') -or
    ([DateTimeOffset]$baseline.generation4Baseline.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne $nextReviewDueAt.ToString('o') -or
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
    throw 'The generation-4 custody baseline timing, generation, sequence, or retention boundary is invalid.'
}

$lineage = [ordered]@{
    renewalEvidenceSha256 = $renewalHash
    renewalEvidenceIntegrityDigest = [string]$renewal.integrityDigest
    approvedPlanSha256 = [string]$renewal.approvedPlan.sha256
    approvedPlanIntegrityDigest = [string]$renewal.approvedPlan.integrityDigest
    approvalDigest = [string]$renewal.approvedPlan.approvalDigest
    previousBaselineSha256 = [string]$renewal.lineage.nextRenewedBaselineSha256
    previousBaselineIntegrityDigest = [string]$renewal.lineage.nextRenewedBaselineIntegrityDigest
    previousLineageDigest = [string]$renewal.lineage.nextRenewedLineageDigest
    previousRenewalEvidenceSha256 = [string]$renewal.lineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$renewal.lineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineage = $renewal.lineage.inheritedLineage
    previousReviewChainDigest = [string]$renewal.lineage.nextRenewedReviewChainDigest
    previousHeadReviewSequence = $previousHeadReviewSequence
    nextReviewSequence = $nextReviewSequence
    previousBaselineGeneration = $previousBaselineGeneration
    baselineGeneration = $baselineGeneration
    previousRenewalSequence = $previousRenewalSequence
    renewalSequence = $renewalSequence
    previousRetentionUntilUtc = $previousRetentionUntil.ToString('o')
    renewedRetentionUntilUtc = $renewedRetentionUntil.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
}
$generation4LineageDigest = Get-Sha256Text -Text ($lineage | ConvertTo-Json -Depth 12 -Compress)
if ([string]$baseline.generation4Baseline.lineageDigest -ne $generation4LineageDigest) {
    throw 'The generation-4 custody lineage digest is invalid.'
}

if (
    [string]$baseline.outcome -ne 'passed' -or
    [bool]$baseline.decision.renewalEvidenceVerified -ne $true -or
    [bool]$baseline.decision.inheritedLineagePreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [bool]$baseline.decision.baselineEstablished -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-generation-4-custody-review'
) {
    throw 'The generation-4 custody baseline decision is not safe to resume the inherited review schedule.'
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
    approvedPlanSha256 = [string]$renewal.approvedPlan.sha256
    approvedPlanIntegrityDigest = [string]$renewal.approvedPlan.integrityDigest
    approvalDigest = [string]$renewal.approvedPlan.approvalDigest
    previousBaselineSha256 = [string]$renewal.lineage.nextRenewedBaselineSha256
    previousBaselineIntegrityDigest = [string]$renewal.lineage.nextRenewedBaselineIntegrityDigest
    previousLineageDigest = [string]$renewal.lineage.nextRenewedLineageDigest
    previousRenewalEvidenceSha256 = [string]$renewal.lineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$renewal.lineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineage = $renewal.lineage.inheritedLineage
    previousReviewChainDigest = [string]$renewal.lineage.nextRenewedReviewChainDigest
    previousHeadReviewSequence = $previousHeadReviewSequence
    nextReviewSequence = $nextReviewSequence
    previousBaselineGeneration = $previousBaselineGeneration
    baselineGeneration = $baselineGeneration
    previousRenewalSequence = $previousRenewalSequence
    renewalSequence = $renewalSequence
    previousRetentionUntilUtc = $previousRetentionUntil.ToString('o')
    renewedRetentionUntilUtc = $renewedRetentionUntil.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    baselineEstablishedAtUtc = $baselineEstablishedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxRenewalEvidenceAgeMinutes = [int]$baseline.freshness.maxRenewalEvidenceAgeMinutes
    maxBaselineEstablishmentAgeMinutes = [int]$baseline.freshness.maxBaselineEstablishmentAgeMinutes
    baselineReference = [string]$baseline.generation4Baseline.baselineReference
    establishedBy = [string]$baseline.operators.establishedBy
    verifiedBy = [string]$baseline.operators.verifiedBy
    generation4LineageDigest = $generation4LineageDigest
    renewalEvidenceVerified = $true
    inheritedLineagePreserved = $true
    priorReviewChainPreserved = $true
    baselineEstablished = $true
    outcome = 'passed'
    nextAction = 'resume-generation-4-custody-review'
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 12 -Compress)) -ne [string]$baseline.integrityDigest) {
    throw 'The generation-4 custody baseline integrity digest is invalid.'
}

Write-Host "Generation-4 custody baseline validation passed for change $($baseline.changeId)."
Write-Host "Generation $baselineGeneration preserves head $previousHeadReviewSequence; review sequence $nextReviewSequence remains due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This validator is read-only and does not schedule reviews, rewrite evidence, or change archives, retention, cluster, traffic, or rollback.'
