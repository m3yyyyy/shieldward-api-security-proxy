[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TriggerEvidencePath,
    [string]$ChainHeadEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PreviousRenewalPlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')][string]$ChangeId,
    [Parameter(Mandatory)][DateTimeOffset]$RequestedRetentionUntilUtc,
    [Parameter(Mandatory)][ValidateSet('extend-existing-object-lock', 'copy-to-new-immutable-generation')][string]$RenewalMethod,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArchiveLocationReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApprovalOwner,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CustodyOwner,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreAuthority,
    [ValidateRange(30, 3650)][int]$MinimumExtensionDays = 365,
    [ValidateRange(1, 3650)][int]$MinimumRemainingDaysAfterNextReview = 180,
    [string]$OutputDirectory = '.shieldward/production-assurance-renewed-retention-renewal-plan',
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

function Assert-Label {
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

foreach ($label in @(
    [pscustomobject]@{ Value = $ArchiveLocationReference; Description = 'ArchiveLocationReference' }
    [pscustomobject]@{ Value = $ApprovalOwner; Description = 'ApprovalOwner' }
    [pscustomobject]@{ Value = $CustodyOwner; Description = 'CustodyOwner' }
    [pscustomobject]@{ Value = $RestoreAuthority; Description = 'RestoreAuthority' }
)) {
    Assert-Label -Value $label.Value -Description $label.Description
}

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedTriggerPath = Resolve-LocalStatePath -Path $TriggerEvidencePath -Description 'TriggerEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedTriggerPath -PathType Leaf)) {
    throw "Renewed retention-renewal trigger evidence is missing: $resolvedTriggerPath"
}
$triggerValidationArguments = @{
    EvidencePath = $resolvedTriggerPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    $triggerValidationArguments.ChainHeadEvidencePath = $ChainHeadEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
    $triggerValidationArguments.BaselinePath = $BaselinePath
}
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    $triggerValidationArguments.RenewalEvidencePath = $RenewalEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($PreviousRenewalPlanPath)) {
    $triggerValidationArguments.PlanPath = $PreviousRenewalPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $triggerValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-chain-audit-evidence.ps1') @triggerValidationArguments 6>$null

$trigger = Get-Content -Raw -LiteralPath $resolvedTriggerPath | ConvertFrom-Json
if (
    [string]$trigger.evidenceType -ne 'renewed-production-assurance-custody-chain-audit' -or
    [string]$trigger.outcome -ne 'failed' -or
    [string]$trigger.audit.evidenceRetentionStatus -ne 'at-risk' -or
    [bool]$trigger.chain.verified -ne $true -or
    [bool]$trigger.chain.baselineVerified -ne $true -or
    [bool]$trigger.chain.renewalVerified -ne $true -or
    [bool]$trigger.chain.originalLineageVerified -ne $true -or
    [bool]$trigger.decision.chainVerified -ne $true -or
    [bool]$trigger.decision.baselineVerified -ne $true -or
    [bool]$trigger.decision.renewalVerified -ne $true -or
    [bool]$trigger.decision.originalLineageVerified -ne $true -or
    [string]$trigger.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'Renewed retention renewal requires exact failed renewed custody chain-audit evidence whose recorded action is renewal.'
}

$currentRetentionUntil = ([DateTimeOffset]$trigger.retention.untilUtc).ToUniversalTime()
$requestedRetentionUntil = $RequestedRetentionUntilUtc.ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$trigger.schedule.nextReviewDueAtUtc).ToUniversalTime()
$minimumRequestedRetention = $currentRetentionUntil.AddDays($MinimumExtensionDays)
$minimumRetentionAfterNextReview = $nextReviewDueAt.AddDays($MinimumRemainingDaysAfterNextReview)
$extensionDays = [math]::Round(($requestedRetentionUntil - $currentRetentionUntil).TotalDays, 6)
$remainingDaysAfterNextReview = [math]::Round(($requestedRetentionUntil - $nextReviewDueAt).TotalDays, 6)
if (
    $referenceNow -ge $currentRetentionUntil -or
    $requestedRetentionUntil -lt $minimumRequestedRetention -or
    $requestedRetentionUntil -lt $minimumRetentionAfterNextReview
) {
    throw 'Requested renewed retention must extend the unexpired boundary and cover the next review by the required minimum.'
}

$currentBaselineGeneration = [int]$trigger.renewedCustodyBaseline.generation
$currentRenewalSequence = [int]$trigger.renewedCustodyBaseline.renewalSequence
$nextBaselineGeneration = $currentBaselineGeneration + 1
$renewalSequence = $currentRenewalSequence + 1
$triggerHash = (Get-FileHash -LiteralPath $resolvedTriggerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$triggerRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedTriggerPath).Replace('\', '/')
$generatedAt = $referenceNow
$requiredApprovalStatement = 'APPROVE RENEWED RETENTION RENEWAL {0} GENERATION {1} FOR {2} UNTIL {3}' -f `
    $ChangeId, $nextBaselineGeneration, $ExpectedProductionContext, $requestedRetentionUntil.ToString('yyyy-MM-dd')
$integrity = [ordered]@{
    triggerEvidenceSha256 = $triggerHash
    triggerEvidenceIntegrityDigest = [string]$trigger.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    incidentId = [string]$trigger.incidentId
    closureChangeId = [string]$trigger.closureChangeId
    releaseVersion = [string]$trigger.candidate.version
    sourceTag = [string]$trigger.candidate.sourceTag
    controlPlaneImage = [string]$trigger.candidate.controlPlaneImage
    edgeImage = [string]$trigger.candidate.edgeImage
    policyVersion = [string]$trigger.candidate.policyVersion
    renewedBaselineSha256 = [string]$trigger.renewedCustodyBaseline.sha256
    renewedBaselineIntegrityDigest = [string]$trigger.renewedCustodyBaseline.integrityDigest
    renewedLineageDigest = [string]$trigger.renewedCustodyBaseline.lineageDigest
    previousRenewalEvidenceSha256 = [string]$trigger.renewalEvidence.sha256
    previousRenewalEvidenceIntegrityDigest = [string]$trigger.renewalEvidence.integrityDigest
    originalCustodySha256 = [string]$trigger.originalCustody.sha256
    originalCustodyIntegrityDigest = [string]$trigger.originalCustody.integrityDigest
    originalCustodyChainDigest = [string]$trigger.originalCustody.chainDigest
    priorReviewChainDigest = [string]$trigger.priorReviewChain.digest
    renewedReviewChainDigest = [string]$trigger.chain.digest
    renewedReviewHeadSequence = [int]$trigger.chain.headSequence
    currentBaselineGeneration = $currentBaselineGeneration
    nextBaselineGeneration = $nextBaselineGeneration
    currentRenewalSequence = $currentRenewalSequence
    renewalSequence = $renewalSequence
    currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
    requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
    renewalMethod = $RenewalMethod
    minimumExtensionDays = $MinimumExtensionDays
    extensionDays = $extensionDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRemainingDaysAfterNextReview = $MinimumRemainingDaysAfterNextReview
    remainingDaysAfterNextReview = $remainingDaysAfterNextReview
    archiveLocationReference = $ArchiveLocationReference
    approvalOwner = $ApprovalOwner
    custodyOwner = $CustodyOwner
    restoreAuthority = $RestoreAuthority
    generatedAtUtc = $generatedAt.ToString('o')
    requiredApprovalStatement = $requiredApprovalStatement
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    planType = 'production-assurance-renewed-retention-renewal-plan'
    state = 'pending'
    generatedAtUtc = $generatedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    incidentId = [string]$trigger.incidentId
    closureChangeId = [string]$trigger.closureChangeId
    candidate = $trigger.candidate
    triggerEvidence = [ordered]@{
        relativePath = $triggerRelativePath
        sha256 = $triggerHash
        integrityDigest = [string]$trigger.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime().ToString('o')
        outcome = [string]$trigger.outcome
        nextAction = [string]$trigger.decision.nextAction
    }
    lineage = [ordered]@{
        renewedBaselineSha256 = [string]$trigger.renewedCustodyBaseline.sha256
        renewedBaselineIntegrityDigest = [string]$trigger.renewedCustodyBaseline.integrityDigest
        renewedLineageDigest = [string]$trigger.renewedCustodyBaseline.lineageDigest
        previousRenewalEvidenceSha256 = [string]$trigger.renewalEvidence.sha256
        previousRenewalEvidenceIntegrityDigest = [string]$trigger.renewalEvidence.integrityDigest
        originalCustodySha256 = [string]$trigger.originalCustody.sha256
        originalCustodyIntegrityDigest = [string]$trigger.originalCustody.integrityDigest
        originalCustodyChainDigest = [string]$trigger.originalCustody.chainDigest
        priorReviewChainDigest = [string]$trigger.priorReviewChain.digest
        renewedReviewChainDigest = [string]$trigger.chain.digest
        renewedReviewHeadSequence = [int]$trigger.chain.headSequence
    }
    renewal = [ordered]@{
        method = $RenewalMethod
        currentBaselineGeneration = $currentBaselineGeneration
        nextBaselineGeneration = $nextBaselineGeneration
        currentRenewalSequence = $currentRenewalSequence
        renewalSequence = $renewalSequence
        currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
        requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
        minimumExtensionDays = $MinimumExtensionDays
        extensionDays = $extensionDays
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        minimumRemainingDaysAfterNextReview = $MinimumRemainingDaysAfterNextReview
        remainingDaysAfterNextReview = $remainingDaysAfterNextReview
        sufficientForNextReview = $true
        archiveLocationReference = $ArchiveLocationReference
    }
    authorities = [ordered]@{
        approvalOwner = $ApprovalOwner
        custodyOwner = $CustodyOwner
        restoreAuthority = $RestoreAuthority
    }
    approval = [ordered]@{
        status = 'pending'
        requiredStatement = $requiredApprovalStatement
        approvedBy = ''
        approvedAtUtc = ''
        approvedAtUnixSeconds = 0
        approvalStatement = ''
        approvalDigest = ''
    }
    decision = [ordered]@{
        lineagePreserved = $true
        eligibleForApproval = $true
        externalExecutionAuthorized = $false
        nextAction = 'obtain-independent-renewed-retention-renewal-approval'
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$safeChangeId = $ChangeId -replace '[^A-Za-z0-9._-]', '-'
$planPath = Join-Path $resolvedOutputDirectory "renewed-retention-renewal-$safeChangeId.json"
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Renewed production assurance retention-renewal plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Pending renewed production assurance retention-renewal plan recorded at $planPath."
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No archive, object-lock, retention, access, restore, scheduler, cluster, traffic, or rollback changes were made.'
