[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$TriggerEvidencePath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateSet('Pending', 'Approved', 'Either')][string]$RequiredState = 'Either',
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production assurance retention-renewal plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.planType -ne 'production-assurance-retention-renewal-plan'
) {
    throw 'The supplied production assurance retention-renewal plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext -or [string]$plan.namespace -ne 'shieldward') {
    throw 'The production assurance retention-renewal plan targets the wrong context or namespace.'
}
if ([string]$plan.changeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$') {
    throw 'The production assurance retention-renewal plan contains an invalid change ID.'
}

$resolvedTriggerPath = if ([string]::IsNullOrWhiteSpace($TriggerEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.triggerEvidence.relativePath) -Description 'Recorded trigger evidence path'
}
else {
    Resolve-LocalStatePath -Path $TriggerEvidencePath -Description 'TriggerEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedTriggerPath -PathType Leaf)) {
    throw "Recorded retention-renewal trigger evidence is missing: $resolvedTriggerPath"
}
$triggerValidationArguments = @{
    EvidencePath = $resolvedTriggerPath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $triggerValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-chain-audit-evidence.ps1') @triggerValidationArguments 6>$null

$trigger = Get-Content -Raw -LiteralPath $resolvedTriggerPath | ConvertFrom-Json
$triggerHash = (Get-FileHash -LiteralPath $resolvedTriggerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$triggerRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedTriggerPath).Replace('\', '/')
if (
    $triggerRelativePath -ne [string]$plan.triggerEvidence.relativePath -or
    $triggerHash -ne [string]$plan.triggerEvidence.sha256 -or
    [string]$trigger.integrityDigest -ne [string]$plan.triggerEvidence.integrityDigest -or
    ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$plan.triggerEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$plan.triggerEvidence.outcome -ne 'failed' -or
    [string]$plan.triggerEvidence.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'The exact failed custody chain-audit trigger no longer matches the retention-renewal plan.'
}
if (
    [string]$trigger.evidenceType -ne 'production-assurance-custody-chain-audit' -or
    [string]$trigger.outcome -ne 'failed' -or
    [string]$trigger.audit.evidenceRetentionStatus -ne 'missing' -or
    [bool]$trigger.chain.verified -ne $true -or
    [bool]$trigger.chain.rootCustodyVerified -ne $true -or
    [string]$trigger.decision.nextAction -ne 'renew-retention-before-continuing'
) {
    throw 'The retention-renewal plan does not have a valid failed custody chain-audit trigger.'
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
    throw 'The retention-renewal plan identity or candidate does not match its trigger.'
}
if (
    [string]$plan.custody.relativePath -ne [string]$trigger.rootCustodyEvidence.relativePath -or
    [string]$plan.custody.sha256 -ne [string]$trigger.rootCustodyEvidence.sha256 -or
    [string]$plan.custody.integrityDigest -ne [string]$trigger.rootCustodyEvidence.integrityDigest -or
    [string]$plan.custody.chainDigest -ne [string]$trigger.rootCustodyEvidence.chainDigest -or
    [string]$plan.custody.reviewChainDigest -ne [string]$trigger.chain.digest -or
    [int]$plan.custody.headReviewSequence -ne [int]$trigger.chain.headSequence
) {
    throw 'The retention-renewal plan changed the root custody or review-chain identity.'
}

foreach ($label in @(
    [pscustomobject]@{ Value = [string]$plan.renewal.archiveLocationReference; Description = 'Archive location reference' }
    [pscustomobject]@{ Value = [string]$plan.authorities.approvalOwner; Description = 'Approval owner' }
    [pscustomobject]@{ Value = [string]$plan.authorities.custodyOwner; Description = 'Custody owner' }
    [pscustomobject]@{ Value = [string]$plan.authorities.restoreAuthority; Description = 'Restore authority' }
)) {
    Assert-Label -Value $label.Value -Description $label.Description
}
if ([string]$plan.renewal.method -notin @('extend-existing-object-lock', 'copy-to-new-immutable-generation')) {
    throw "The retention-renewal plan contains unsupported method '$($plan.renewal.method)'."
}

$triggerCollectedAt = ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime()
$generatedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$trigger.rootCustodyEvidence.retentionUntilUtc).ToUniversalTime()
$recordedCurrentRetentionUntil = ([DateTimeOffset]$plan.custody.currentRetentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$trigger.chain.entries[-1].nextReviewDueAtUtc).ToUniversalTime()
$recordedNextReviewDueAt = ([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime()
$minimumExtensionDays = [int]$plan.renewal.minimumExtensionDays
$minimumRemainingDays = [int]$plan.renewal.minimumRemainingDaysAfterNextReview
$extensionDays = [math]::Round(($requestedRetentionUntil - $currentRetentionUntil).TotalDays, 6)
$remainingDaysAfterNextReview = [math]::Round(($requestedRetentionUntil - $nextReviewDueAt).TotalDays, 6)
if (
    $recordedCurrentRetentionUntil.ToString('o') -ne $currentRetentionUntil.ToString('o') -or
    $recordedNextReviewDueAt.ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    $minimumExtensionDays -lt 30 -or
    $minimumExtensionDays -gt 3650 -or
    $minimumRemainingDays -lt 1 -or
    $minimumRemainingDays -gt 3650 -or
    [double]$plan.renewal.extensionDays -ne $extensionDays -or
    [double]$plan.renewal.remainingDaysAfterNextReview -ne $remainingDaysAfterNextReview -or
    $requestedRetentionUntil -lt $currentRetentionUntil.AddDays($minimumExtensionDays) -or
    $requestedRetentionUntil -lt $nextReviewDueAt.AddDays($minimumRemainingDays) -or
    [bool]$plan.renewal.sufficientForNextReview -ne $true -or
    $generatedAt -lt $triggerCollectedAt -or
    $generatedAt -ge $currentRetentionUntil -or
    $referenceNow -lt $generatedAt.AddMinutes(-5)
) {
    throw 'The production assurance retention-renewal duration, review coverage, or timing boundary is invalid.'
}

$requiredApprovalStatement = 'APPROVE RETENTION RENEWAL {0} FOR {1} UNTIL {2}' -f `
    [string]$plan.changeId, $ExpectedProductionContext, $requestedRetentionUntil.ToString('yyyy-MM-dd')
if ([string]$plan.approval.requiredStatement -ne $requiredApprovalStatement) {
    throw 'The production assurance retention-renewal approval statement is invalid.'
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
    rootCustodyEvidenceSha256 = [string]$trigger.rootCustodyEvidence.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$trigger.rootCustodyEvidence.integrityDigest
    rootCustodyChainDigest = [string]$trigger.rootCustodyEvidence.chainDigest
    custodyReviewChainDigest = [string]$trigger.chain.digest
    custodyReviewHeadSequence = [int]$trigger.chain.headSequence
    currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
    requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
    renewalMethod = [string]$plan.renewal.method
    minimumExtensionDays = $minimumExtensionDays
    extensionDays = $extensionDays
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRemainingDaysAfterNextReview = $minimumRemainingDays
    remainingDaysAfterNextReview = $remainingDaysAfterNextReview
    archiveLocationReference = [string]$plan.renewal.archiveLocationReference
    approvalOwner = [string]$plan.authorities.approvalOwner
    custodyOwner = [string]$plan.authorities.custodyOwner
    restoreAuthority = [string]$plan.authorities.restoreAuthority
    generatedAtUtc = $generatedAt.ToString('o')
    requiredApprovalStatement = $requiredApprovalStatement
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production assurance retention-renewal plan integrity digest is invalid.'
}

$state = [string]$plan.state
$approvalStatus = [string]$plan.approval.status
if ($RequiredState -eq 'Pending' -and ($state -ne 'pending' -or $approvalStatus -ne 'pending')) {
    throw "The retention-renewal plan is '$state'; expected pending."
}
if ($RequiredState -eq 'Approved' -and ($state -ne 'approved' -or $approvalStatus -ne 'approved')) {
    throw "The retention-renewal plan is '$state'; expected approved."
}
if ($RequiredState -eq 'Either' -and $state -notin @('pending', 'approved')) {
    throw "The retention-renewal plan has unsupported state '$state'."
}

if ($state -eq 'pending') {
    if (
        $approvalStatus -ne 'pending' -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvedBy) -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvedAtUtc) -or
        [long]$plan.approval.approvedAtUnixSeconds -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvalStatement) -or
        -not [string]::IsNullOrEmpty([string]$plan.approval.approvalDigest) -or
        [bool]$plan.decision.eligibleForApproval -ne $true -or
        [bool]$plan.decision.externalExecutionAuthorized -ne $false -or
        [string]$plan.decision.nextAction -ne 'obtain-independent-retention-renewal-approval'
    ) {
        throw 'A pending retention-renewal plan contains an inconsistent approval or decision state.'
    }
}
elseif ($state -eq 'approved') {
    $approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if (
        $approvalStatus -ne 'approved' -or
        [string]$plan.approval.approvedBy -ne [string]$plan.authorities.approvalOwner -or
        [string]$plan.approval.approvalStatement -ne $requiredApprovalStatement -or
        $approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds() -or
        $approvedAt -lt $generatedAt -or
        $approvedAt -ge $currentRetentionUntil -or
        $referenceNow -lt $approvedAt.AddMinutes(-5) -or
        [bool]$plan.decision.eligibleForApproval -ne $true -or
        [bool]$plan.decision.externalExecutionAuthorized -ne $true -or
        [string]$plan.decision.nextAction -ne 'execute-approved-external-retention-renewal'
    ) {
        throw 'The approved retention-renewal identity, timing, or decision state is invalid.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The production assurance retention-renewal approval digest is invalid.'
    }
}

Write-Host "Production assurance retention-renewal plan validation passed in '$state' state."
Write-Host "Requested retention: $($requestedRetentionUntil.ToString('o')); next review: $($nextReviewDueAt.ToString('o'))"
Write-Host 'This validator is read-only and does not renew retention, alter archives, restore evidence, or change production.'
