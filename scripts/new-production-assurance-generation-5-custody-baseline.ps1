[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RenewalEvidencePath,
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$BaselineEstablishedAtUtc,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BaselineReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EstablishedBy,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VerifiedBy,
    [ValidateRange(5, 1440)][int]$MaxRenewalEvidenceAgeMinutes = 60,
    [ValidateRange(5, 1440)][int]$MaxBaselineEstablishmentAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-generation-5-custody-baseline',
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
    [pscustomobject]@{ Value = $BaselineReference; Description = 'BaselineReference' }
    [pscustomobject]@{ Value = $EstablishedBy; Description = 'EstablishedBy' }
    [pscustomobject]@{ Value = $VerifiedBy; Description = 'VerifiedBy' }
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

$resolvedRenewalEvidencePath = Resolve-LocalStatePath -Path $RenewalEvidencePath -Description 'RenewalEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedRenewalEvidencePath -PathType Leaf)) {
    throw "Passed renewed retention-renewal evidence is missing: $resolvedRenewalEvidencePath"
}
$renewalGateArguments = @{
    EvidencePath = $resolvedRenewalEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    MaxEvidenceAgeMinutes = $MaxRenewalEvidenceAgeMinutes
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $renewalGateArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $renewalGateArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-4-retention-renewal-evidence-gate.ps1') @renewalGateArguments 6>$null

$renewal = Get-Content -Raw -LiteralPath $resolvedRenewalEvidencePath | ConvertFrom-Json
$renewalCollectedAt = ([DateTimeOffset]$renewal.collectedAtUtc).ToUniversalTime()
$renewalCompletedAt = ([DateTimeOffset]$renewal.execution.completedAtUtc).ToUniversalTime()
$baselineEstablishedAt = $BaselineEstablishedAtUtc.ToUniversalTime()
$previousRetentionUntil = ([DateTimeOffset]$renewal.renewal.currentRetentionUntilUtc).ToUniversalTime()
$renewedRetentionUntil = ([DateTimeOffset]$renewal.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$renewal.renewal.nextReviewDueAtUtc).ToUniversalTime()
$baselineAge = $referenceNow - $baselineEstablishedAt
if (
    $baselineEstablishedAt -lt $renewalCollectedAt -or
    $baselineEstablishedAt -lt $renewalCompletedAt -or
    $baselineEstablishedAt -ge $nextReviewDueAt -or
    $baselineEstablishedAt -ge $renewedRetentionUntil -or
    $baselineAge.TotalMinutes -lt -5 -or
    $baselineAge.TotalMinutes -gt $MaxBaselineEstablishmentAgeMinutes
) {
    throw 'The generation-5 custody baseline must follow passed renewal evidence, precede the inherited review and retention deadlines, and remain fresh.'
}

$previousBaselineGeneration = [int]$renewal.renewal.currentBaselineGeneration
$baselineGeneration = [int]$renewal.renewal.nextBaselineGeneration
$previousRenewalSequence = [int]$renewal.renewal.currentRenewalSequence
$renewalSequence = [int]$renewal.renewal.renewalSequence
$previousHeadReviewSequence = [int]$renewal.lineage.generation4ReviewHeadSequence
$nextReviewSequence = $previousHeadReviewSequence + 1
if (
    $baselineGeneration -ne ($previousBaselineGeneration + 1) -or
    $renewalSequence -ne ($previousRenewalSequence + 1) -or
    $renewedRetentionUntil -le $previousRetentionUntil
) {
    throw 'Renewal evidence does not advance the baseline generation, renewal sequence, and retention boundary exactly once.'
}

$renewalHash = (Get-FileHash -LiteralPath $resolvedRenewalEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$renewalRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedRenewalEvidencePath).Replace('\', '/')
$lineage = [ordered]@{
    renewalEvidenceSha256 = $renewalHash
    renewalEvidenceIntegrityDigest = [string]$renewal.integrityDigest
    approvedPlanSha256 = [string]$renewal.approvedPlan.sha256
    approvedPlanIntegrityDigest = [string]$renewal.approvedPlan.integrityDigest
    approvalDigest = [string]$renewal.approvedPlan.approvalDigest
    previousBaselineSha256 = [string]$renewal.lineage.generation4BaselineSha256
    previousBaselineIntegrityDigest = [string]$renewal.lineage.generation4BaselineIntegrityDigest
    previousLineageDigest = [string]$renewal.lineage.generation4LineageDigest
    previousRenewalEvidenceSha256 = [string]$renewal.lineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$renewal.lineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineage = $renewal.lineage.inheritedLineage
    previousReviewChainDigest = [string]$renewal.lineage.generation4ReviewChainDigest
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
$generation5LineageDigest = Get-Sha256Text -Text ($lineage | ConvertTo-Json -Depth 12 -Compress)

$collectedAt = $referenceNow
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
    previousBaselineSha256 = [string]$renewal.lineage.generation4BaselineSha256
    previousBaselineIntegrityDigest = [string]$renewal.lineage.generation4BaselineIntegrityDigest
    previousLineageDigest = [string]$renewal.lineage.generation4LineageDigest
    previousRenewalEvidenceSha256 = [string]$renewal.lineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$renewal.lineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineage = $renewal.lineage.inheritedLineage
    previousReviewChainDigest = [string]$renewal.lineage.generation4ReviewChainDigest
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
    maxRenewalEvidenceAgeMinutes = $MaxRenewalEvidenceAgeMinutes
    maxBaselineEstablishmentAgeMinutes = $MaxBaselineEstablishmentAgeMinutes
    baselineReference = $BaselineReference
    establishedBy = $EstablishedBy
    verifiedBy = $VerifiedBy
    generation5LineageDigest = $generation5LineageDigest
    renewalEvidenceVerified = $true
    inheritedLineagePreserved = $true
    priorReviewChainPreserved = $true
    baselineEstablished = $true
    outcome = 'passed'
    nextAction = 'resume-generation-5-custody-review'
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 12 -Compress)

$baseline = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'production-assurance-generation-5-custody-baseline'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$renewal.changeId
    incidentId = [string]$renewal.incidentId
    closureChangeId = [string]$renewal.closureChangeId
    candidate = $renewal.candidate
    renewalEvidence = [ordered]@{
        relativePath = $renewalRelativePath
        sha256 = $renewalHash
        integrityDigest = [string]$renewal.integrityDigest
        collectedAtUtc = $renewalCollectedAt.ToString('o')
        executionCompletedAtUtc = $renewalCompletedAt.ToString('o')
        outcome = [string]$renewal.outcome
        retentionRenewalProven = [bool]$renewal.decision.retentionRenewalProven
    }
    inheritedLineage = $renewal.lineage
    generation5Baseline = [ordered]@{
        previousGeneration = $previousBaselineGeneration
        generation = $baselineGeneration
        previousRenewalSequence = $previousRenewalSequence
        renewalSequence = $renewalSequence
        establishedAtUtc = $baselineEstablishedAt.ToString('o')
        previousHeadReviewSequence = $previousHeadReviewSequence
        nextReviewSequence = $nextReviewSequence
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        previousRetentionUntilUtc = $previousRetentionUntil.ToString('o')
        renewedRetentionUntilUtc = $renewedRetentionUntil.ToString('o')
        lineageDigest = $generation5LineageDigest
        baselineReference = $BaselineReference
    }
    freshness = [ordered]@{
        maxRenewalEvidenceAgeMinutes = $MaxRenewalEvidenceAgeMinutes
        maxBaselineEstablishmentAgeMinutes = $MaxBaselineEstablishmentAgeMinutes
    }
    operators = [ordered]@{
        establishedBy = $EstablishedBy
        verifiedBy = $VerifiedBy
    }
    decision = [ordered]@{
        renewalEvidenceVerified = $true
        inheritedLineagePreserved = $true
        priorReviewChainPreserved = $true
        baselineEstablished = $true
        nextAction = 'resume-generation-5-custody-review'
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$safeChangeId = ([string]$renewal.changeId) -replace '[^A-Za-z0-9._-]', '-'
$fileName = 'generation-5-custody-baseline-{0}-{1}.json' -f $safeChangeId, $collectedAt.ToString('yyyyMMddTHHmmssZ')
$baselinePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $baselinePath) -and -not $Force) {
    throw "Generation-5 custody baseline already exists: $baselinePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $baselinePath,
    (($baseline | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Generation-5 custody baseline recorded at $baselinePath."
Write-Host "Generation $baselineGeneration preserves review head $previousHeadReviewSequence; review sequence $nextReviewSequence remains due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'No review was scheduled, no evidence was rewritten, and no archive, retention, cluster, traffic, or rollback changes were made.'

