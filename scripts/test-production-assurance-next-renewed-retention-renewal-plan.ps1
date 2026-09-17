[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$TriggerEvidencePath = '',
    [string]$ChainHeadEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PreviousRenewalPlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateSet('Any', 'Pending', 'Approved')][string]$RequiredState = 'Any',
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

function Test-JsonEqual {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    return (($Left | ConvertTo-Json -Depth 12 -Compress) -eq ($Right | ConvertTo-Json -Depth 12 -Compress))
}

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Next renewed production assurance retention-renewal plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.planType -ne 'production-assurance-next-renewed-retention-renewal-plan'
) {
    throw 'The supplied next-renewed retention-renewal plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext -or [string]$plan.namespace -ne 'shieldward') {
    throw 'The next-renewed retention-renewal plan targets the wrong context or namespace.'
}

$resolvedTriggerPath = if ([string]::IsNullOrWhiteSpace($TriggerEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.triggerEvidence.relativePath) -Description 'Recorded trigger evidence path'
}
else {
    Resolve-LocalStatePath -Path $TriggerEvidencePath -Description 'TriggerEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedTriggerPath -PathType Leaf)) {
    throw "Recorded renewed custody chain-audit trigger is missing: $resolvedTriggerPath"
}
$triggerValidationArguments = @{
    EvidencePath = $resolvedTriggerPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) { $triggerValidationArguments.ChainHeadEvidencePath = $ChainHeadEvidencePath }
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) { $triggerValidationArguments.BaselinePath = $BaselinePath }
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) { $triggerValidationArguments.RenewalEvidencePath = $RenewalEvidencePath }
if (-not [string]::IsNullOrWhiteSpace($PreviousRenewalPlanPath)) { $triggerValidationArguments.PlanPath = $PreviousRenewalPlanPath }
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) { $triggerValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc }
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @triggerValidationArguments 6>$null

$trigger = Get-Content -Raw -LiteralPath $resolvedTriggerPath | ConvertFrom-Json
$triggerHash = (Get-FileHash -LiteralPath $resolvedTriggerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$triggerRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedTriggerPath).Replace('\', '/')
if (
    $triggerRelativePath -ne [string]$plan.triggerEvidence.relativePath -or
    $triggerHash -ne [string]$plan.triggerEvidence.sha256 -or
    [string]$trigger.integrityDigest -ne [string]$plan.triggerEvidence.integrityDigest -or
    ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$plan.triggerEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$trigger.outcome -ne [string]$plan.triggerEvidence.outcome -or
    [string]$trigger.decision.nextAction -ne [string]$plan.triggerEvidence.nextAction
) {
    throw 'The exact generation-3 custody chain-audit trigger no longer matches the plan.'
}
if (
    [string]$trigger.evidenceType -ne 'next-renewed-production-assurance-custody-chain-audit' -or
    [string]$trigger.outcome -ne 'failed' -or
    [string]$trigger.audit.evidenceRetentionStatus -ne 'at-risk' -or
    [bool]$trigger.chain.verified -ne $true -or
    [bool]$trigger.chain.baselineVerified -ne $true -or
    [bool]$trigger.chain.renewalVerified -ne $true -or
    [bool]$trigger.chain.inheritedLineageVerified -ne $true -or
    [bool]$trigger.decision.chainVerified -ne $true -or
    [bool]$trigger.decision.baselineVerified -ne $true -or
    [bool]$trigger.decision.renewalVerified -ne $true -or
    [bool]$trigger.decision.inheritedLineageVerified -ne $true -or
    [string]$trigger.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'The next-renewed retention-renewal trigger is not an exact failed retention-at-risk audit.'
}
if (
    [string]$plan.incidentId -ne [string]$trigger.incidentId -or
    [string]$plan.closureChangeId -ne [string]$trigger.closureChangeId -or
    [string]$plan.candidate.version -ne [string]$trigger.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$trigger.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$trigger.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$trigger.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$trigger.candidate.policyVersion
) {
    throw 'The next-renewed retention-renewal plan changed the production identity or candidate.'
}

$lineageContracts = @(
    [pscustomobject]@{ Actual = [string]$plan.lineage.nextRenewedBaselineSha256; Expected = [string]$trigger.nextRenewedCustodyBaseline.sha256 }
    [pscustomobject]@{ Actual = [string]$plan.lineage.nextRenewedBaselineIntegrityDigest; Expected = [string]$trigger.nextRenewedCustodyBaseline.integrityDigest }
    [pscustomobject]@{ Actual = [string]$plan.lineage.nextRenewedLineageDigest; Expected = [string]$trigger.nextRenewedCustodyBaseline.lineageDigest }
    [pscustomobject]@{ Actual = [string]$plan.lineage.previousRenewalEvidenceSha256; Expected = [string]$trigger.renewalEvidence.sha256 }
    [pscustomobject]@{ Actual = [string]$plan.lineage.previousRenewalEvidenceIntegrityDigest; Expected = [string]$trigger.renewalEvidence.integrityDigest }
    [pscustomobject]@{ Actual = [string]$plan.lineage.nextRenewedReviewChainDigest; Expected = [string]$trigger.chain.digest }
)
foreach ($contract in $lineageContracts) {
    if ($contract.Actual -ne $contract.Expected) {
        throw 'The next-renewed retention-renewal plan rewrote the inherited custody lineage.'
    }
}
if (
    [int]$plan.lineage.nextRenewedReviewHeadSequence -ne [int]$trigger.chain.headSequence -or
    -not (Test-JsonEqual -Left $plan.lineage.inheritedLineage -Right $trigger.inheritedLineage)
) {
    throw 'The next-renewed retention-renewal plan changed the renewed review head sequence.'
}

foreach ($label in @(
    [pscustomobject]@{ Value = [string]$plan.renewal.archiveLocationReference; Description = 'Archive location reference' }
    [pscustomobject]@{ Value = [string]$plan.authorities.approvalOwner; Description = 'Approval owner' }
    [pscustomobject]@{ Value = [string]$plan.authorities.custodyOwner; Description = 'Custody owner' }
    [pscustomobject]@{ Value = [string]$plan.authorities.restoreAuthority; Description = 'Restore authority' }
)) { Assert-Label -Value $label.Value -Description $label.Description }

$generatedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$triggerCollectedAt = ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$trigger.retention.untilUtc).ToUniversalTime()
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$trigger.schedule.nextReviewDueAtUtc).ToUniversalTime()
$minimumRequestedRetention = $currentRetentionUntil.AddDays([int]$plan.renewal.minimumExtensionDays)
$minimumRetentionAfterNextReview = $nextReviewDueAt.AddDays([int]$plan.renewal.minimumRemainingDaysAfterNextReview)
$extensionDays = [math]::Round(($requestedRetentionUntil - $currentRetentionUntil).TotalDays, 6)
$remainingDaysAfterNextReview = [math]::Round(($requestedRetentionUntil - $nextReviewDueAt).TotalDays, 6)
$currentBaselineGeneration = [int]$trigger.nextRenewedCustodyBaseline.generation
$currentRenewalSequence = [int]$trigger.nextRenewedCustodyBaseline.renewalSequence
$nextBaselineGeneration = $currentBaselineGeneration + 1
$renewalSequence = $currentRenewalSequence + 1
if (
    $generatedAt -lt $triggerCollectedAt -or
    $referenceNow -lt $generatedAt.AddMinutes(-5) -or
    $generatedAt -ge $currentRetentionUntil -or
    [int]$plan.renewal.minimumExtensionDays -lt 30 -or
    [int]$plan.renewal.minimumExtensionDays -gt 3650 -or
    [int]$plan.renewal.minimumRemainingDaysAfterNextReview -lt 1 -or
    [int]$plan.renewal.minimumRemainingDaysAfterNextReview -gt 3650 -or
    $requestedRetentionUntil -lt $minimumRequestedRetention -or
    $requestedRetentionUntil -lt $minimumRetentionAfterNextReview -or
    ([DateTimeOffset]$plan.renewal.currentRetentionUntilUtc).ToUniversalTime().ToString('o') -ne $currentRetentionUntil.ToString('o') -or
    ([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime().ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [double]$plan.renewal.extensionDays -ne $extensionDays -or
    [double]$plan.renewal.remainingDaysAfterNextReview -ne $remainingDaysAfterNextReview -or
    [int]$plan.renewal.currentBaselineGeneration -ne $currentBaselineGeneration -or
    [int]$plan.renewal.nextBaselineGeneration -ne $nextBaselineGeneration -or
    [int]$plan.renewal.currentRenewalSequence -ne $currentRenewalSequence -or
    [int]$plan.renewal.renewalSequence -ne $renewalSequence -or
    [bool]$plan.renewal.sufficientForNextReview -ne $true -or
    @('extend-existing-object-lock', 'copy-to-new-immutable-generation') -notcontains [string]$plan.renewal.method
) {
    throw 'The next-renewed retention-renewal generation, extension, next-review coverage, or timing is invalid.'
}

$requiredApprovalStatement = 'APPROVE NEXT RENEWED RETENTION RENEWAL {0} GENERATION {1} FOR {2} UNTIL {3}' -f `
    [string]$plan.changeId, $nextBaselineGeneration, $ExpectedProductionContext, $requestedRetentionUntil.ToString('yyyy-MM-dd')
if ([string]$plan.approval.requiredStatement -ne $requiredApprovalStatement) {
    throw 'The next-renewed retention-renewal approval statement does not match the derived boundary.'
}

$integrity = [ordered]@{
    triggerEvidenceSha256 = $triggerHash
    triggerEvidenceIntegrityDigest = [string]$trigger.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$plan.changeId
    incidentId = [string]$trigger.incidentId
    closureChangeId = [string]$trigger.closureChangeId
    releaseVersion = [string]$trigger.candidate.version
    sourceTag = [string]$trigger.candidate.sourceTag
    controlPlaneImage = [string]$trigger.candidate.controlPlaneImage
    edgeImage = [string]$trigger.candidate.edgeImage
    policyVersion = [string]$trigger.candidate.policyVersion
    nextRenewedBaselineSha256 = [string]$trigger.nextRenewedCustodyBaseline.sha256
    nextRenewedBaselineIntegrityDigest = [string]$trigger.nextRenewedCustodyBaseline.integrityDigest
    nextRenewedLineageDigest = [string]$trigger.nextRenewedCustodyBaseline.lineageDigest
    previousRenewalEvidenceSha256 = [string]$trigger.renewalEvidence.sha256
    previousRenewalEvidenceIntegrityDigest = [string]$trigger.renewalEvidence.integrityDigest
    inheritedLineageDigest = Get-Sha256Text -Text ($trigger.inheritedLineage | ConvertTo-Json -Depth 12 -Compress)
    nextRenewedReviewChainDigest = [string]$trigger.chain.digest
    nextRenewedReviewHeadSequence = [int]$trigger.chain.headSequence
    currentBaselineGeneration = $currentBaselineGeneration
    nextBaselineGeneration = $nextBaselineGeneration
    currentRenewalSequence = $currentRenewalSequence
    renewalSequence = $renewalSequence
    currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
    requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
    renewalMethod = [string]$plan.renewal.method
    minimumExtensionDays = [int]$plan.renewal.minimumExtensionDays
    extensionDays = $extensionDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRemainingDaysAfterNextReview = [int]$plan.renewal.minimumRemainingDaysAfterNextReview
    remainingDaysAfterNextReview = $remainingDaysAfterNextReview
    archiveLocationReference = [string]$plan.renewal.archiveLocationReference
    approvalOwner = [string]$plan.authorities.approvalOwner
    custodyOwner = [string]$plan.authorities.custodyOwner
    restoreAuthority = [string]$plan.authorities.restoreAuthority
    generatedAtUtc = $generatedAt.ToString('o')
    requiredApprovalStatement = $requiredApprovalStatement
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The next-renewed production assurance retention-renewal plan integrity digest is invalid.'
}

$normalizedRequiredState = $RequiredState.ToLowerInvariant()
if ($normalizedRequiredState -ne 'any' -and [string]$plan.state -ne $normalizedRequiredState) {
    throw "The next-renewed retention-renewal plan must be in '$normalizedRequiredState' state."
}
if ([string]$plan.state -eq 'pending') {
    if (
        [string]$plan.approval.status -ne 'pending' -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvedBy) -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvedAtUtc) -or
        [long]$plan.approval.approvedAtUnixSeconds -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvalStatement) -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvalDigest) -or
        [bool]$plan.decision.lineagePreserved -ne $true -or
        [bool]$plan.decision.eligibleForApproval -ne $true -or
        [bool]$plan.decision.externalExecutionAuthorized -ne $false -or
        [string]$plan.decision.nextAction -ne 'obtain-independent-next-renewed-retention-renewal-approval'
    ) { throw 'The pending next-renewed retention-renewal approval boundary is invalid.' }
}
elseif ([string]$plan.state -eq 'approved') {
    Assert-Label -Value ([string]$plan.approval.approvedBy) -Description 'Approved by'
    $approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$($approvedAt.ToUnixTimeSeconds())|$requiredApprovalStatement"
    if (
        [string]$plan.approval.status -ne 'approved' -or
        [string]$plan.approval.approvedBy -ne [string]$plan.authorities.approvalOwner -or
        [long]$plan.approval.approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds() -or
        $approvedAt -lt $generatedAt -or
        [string]$plan.approval.approvalStatement -ne $requiredApprovalStatement -or
        [string]$plan.approval.approvalDigest -ne (Get-Sha256Text -Text $approvalInput) -or
        [bool]$plan.decision.lineagePreserved -ne $true -or
        [bool]$plan.decision.eligibleForApproval -ne $true -or
        [bool]$plan.decision.externalExecutionAuthorized -ne $true -or
        [string]$plan.decision.nextAction -ne 'execute-approved-external-next-renewed-retention-renewal'
    ) { throw 'The approved next-renewed retention-renewal boundary or approval digest is invalid.' }
}
else {
    throw "The next-renewed retention-renewal plan state '$($plan.state)' is unsupported."
}

Write-Host "Next renewed production assurance retention-renewal plan validation passed in '$($plan.state)' state."
Write-Host "Renewal sequence $renewalSequence will establish baseline generation $nextBaselineGeneration."
Write-Host 'This validator is read-only and does not alter retention, archives, access, restores, or production.'
