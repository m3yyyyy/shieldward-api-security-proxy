[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
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

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production assurance retention-renewal evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'production-assurance-retention-renewal-evidence'
) {
    throw 'The supplied production assurance retention-renewal evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext -or [string]$evidence.namespace -ne 'shieldward') {
    throw 'The production assurance retention-renewal evidence targets the wrong context or namespace.'
}

$resolvedPlanPath = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.approvedPlan.relativePath) -Description 'Recorded approved plan path'
}
else {
    Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Recorded approved retention-renewal plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $planValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
if (
    $planRelativePath -ne [string]$evidence.approvedPlan.relativePath -or
    $planHash -ne [string]$evidence.approvedPlan.sha256 -or
    [string]$plan.integrityDigest -ne [string]$evidence.approvedPlan.integrityDigest -or
    [string]$plan.approval.approvalDigest -ne [string]$evidence.approvedPlan.approvalDigest -or
    $approvedAt.ToString('o') -ne ([DateTimeOffset]$evidence.approvedPlan.approvedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.approvedPlan.state -ne 'approved' -or
    [string]$evidence.approvedPlan.nextAction -ne 'execute-approved-external-retention-renewal'
) {
    throw 'The exact approved retention-renewal plan no longer matches execution evidence.'
}
if (
    [string]$evidence.changeId -ne [string]$plan.changeId -or
    [string]$evidence.incidentId -ne [string]$plan.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$plan.closureChangeId -or
    [string]$evidence.candidate.version -ne [string]$plan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$plan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$plan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$plan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$plan.candidate.policyVersion
) {
    throw 'The retention-renewal evidence identity or candidate does not match its approved plan.'
}
if (
    [string]$evidence.rootCustody.relativePath -ne [string]$plan.custody.relativePath -or
    [string]$evidence.rootCustody.sha256 -ne [string]$plan.custody.sha256 -or
    [string]$evidence.rootCustody.integrityDigest -ne [string]$plan.custody.integrityDigest -or
    [string]$evidence.rootCustody.chainDigest -ne [string]$plan.custody.chainDigest -or
    [string]$evidence.rootCustody.reviewChainDigest -ne [string]$plan.custody.reviewChainDigest -or
    [int]$evidence.rootCustody.headReviewSequence -ne [int]$plan.custody.headReviewSequence
) {
    throw 'The retention-renewal evidence changed the original custody or review-chain identity.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'external change'; Actual = [string]$evidence.execution.externalChangeStatus; Allowed = @('completed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'retention policy'; Actual = [string]$evidence.controls.retentionPolicy; Allowed = @('active', 'inactive', 'unknown') }
    [pscustomobject]@{ Name = 'object lock'; Actual = [string]$evidence.controls.objectLock; Allowed = @('enforced', 'not-enforced', 'unknown') }
    [pscustomobject]@{ Name = 'archive inventory'; Actual = [string]$evidence.controls.archiveInventory; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'encryption'; Actual = [string]$evidence.controls.encryption; Allowed = @('verified', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'access control'; Actual = [string]$evidence.controls.accessControl; Allowed = @('least-privilege', 'overbroad', 'unknown') }
    [pscustomobject]@{ Name = 'restore verification'; Actual = [string]$evidence.controls.restoreVerification; Allowed = @('passed', 'failed', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "Retention-renewal evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.externalChangeReference; Description = 'External change reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.retentionPolicyReference; Description = 'Retention policy reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.objectLockReference; Description = 'Object lock reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.archiveInventoryReference; Description = 'Archive inventory reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.encryptionReference; Description = 'Encryption reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.accessReviewReference; Description = 'Access review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.restoreTestReference; Description = 'Restore test reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.executedBy; Description = 'Executed by' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.verifiedBy; Description = 'Verified by' }
)) {
    Assert-Reference -Value $reference.Value -Description $reference.Description
}

$planGeneratedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$plan.custody.currentRetentionUntilUtc).ToUniversalTime()
$recordedCurrentRetentionUntil = ([DateTimeOffset]$evidence.rootCustody.currentRetentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$recordedRequestedRetentionUntil = ([DateTimeOffset]$evidence.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$observedRetentionUntil = ([DateTimeOffset]$evidence.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime()
$recordedNextReviewDueAt = ([DateTimeOffset]$evidence.renewal.nextReviewDueAtUtc).ToUniversalTime()
$minimumRemainingDays = [int]$plan.renewal.minimumRemainingDaysAfterNextReview
$remainingDaysAfterNextReview = [math]::Round(($observedRetentionUntil - $nextReviewDueAt).TotalDays, 6)
$retentionExtended = $observedRetentionUntil -gt $currentRetentionUntil
$observedMeetsApprovedBoundary = $observedRetentionUntil -ge $requestedRetentionUntil
$observedCoversNextReview = $remainingDaysAfterNextReview -ge $minimumRemainingDays
$executionCompletedAt = ([DateTimeOffset]$evidence.execution.completedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$planAgeAtCollection = $collectedAt - $planGeneratedAt
$approvalAgeAtCollection = $collectedAt - $approvedAt
$executionAgeAtCollection = $collectedAt - $executionCompletedAt
if (
    $recordedCurrentRetentionUntil.ToString('o') -ne $currentRetentionUntil.ToString('o') -or
    $recordedRequestedRetentionUntil.ToString('o') -ne $requestedRetentionUntil.ToString('o') -or
    $recordedNextReviewDueAt.ToString('o') -ne $nextReviewDueAt.ToString('o') -or
    [int]$evidence.renewal.minimumRemainingDaysAfterNextReview -ne $minimumRemainingDays -or
    [double]$evidence.renewal.remainingDaysAfterNextReview -ne $remainingDaysAfterNextReview -or
    [bool]$evidence.renewal.retentionExtended -ne $retentionExtended -or
    [bool]$evidence.renewal.observedMeetsApprovedBoundary -ne $observedMeetsApprovedBoundary -or
    [bool]$evidence.renewal.observedCoversNextReview -ne $observedCoversNextReview -or
    [string]$evidence.renewal.method -ne [string]$plan.renewal.method -or
    [string]$evidence.renewal.archiveLocationReference -ne [string]$plan.renewal.archiveLocationReference -or
    [int]$evidence.execution.maxApprovedPlanAgeMinutes -lt 5 -or
    [int]$evidence.execution.maxApprovedPlanAgeMinutes -gt 1440 -or
    [int]$evidence.execution.maxExecutionEvidenceAgeMinutes -lt 5 -or
    [int]$evidence.execution.maxExecutionEvidenceAgeMinutes -gt 1440 -or
    $planAgeAtCollection.TotalMinutes -lt -5 -or
    $planAgeAtCollection.TotalMinutes -gt [int]$evidence.execution.maxApprovedPlanAgeMinutes -or
    $approvalAgeAtCollection.TotalMinutes -lt -5 -or
    $approvalAgeAtCollection.TotalMinutes -gt [int]$evidence.execution.maxApprovedPlanAgeMinutes -or
    $executionCompletedAt -lt $approvedAt -or
    $executionCompletedAt -ge $currentRetentionUntil -or
    $executionAgeAtCollection.TotalMinutes -lt -5 -or
    $executionAgeAtCollection.TotalMinutes -gt [int]$evidence.execution.maxExecutionEvidenceAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The production assurance retention-renewal execution, duration, or freshness boundary is invalid.'
}

$hasFailure = (
    [string]$evidence.execution.externalChangeStatus -eq 'failed' -or
    [string]$evidence.controls.retentionPolicy -eq 'inactive' -or
    [string]$evidence.controls.objectLock -eq 'not-enforced' -or
    [string]$evidence.controls.archiveInventory -eq 'incomplete' -or
    [string]$evidence.controls.encryption -eq 'failed' -or
    [string]$evidence.controls.accessControl -eq 'overbroad' -or
    [string]$evidence.controls.restoreVerification -eq 'failed' -or
    -not $retentionExtended -or
    -not $observedMeetsApprovedBoundary -or
    -not $observedCoversNextReview
)
$hasUnknown = @(
    [string]$evidence.execution.externalChangeStatus,
    [string]$evidence.controls.retentionPolicy,
    [string]$evidence.controls.objectLock,
    [string]$evidence.controls.archiveInventory,
    [string]$evidence.controls.encryption,
    [string]$evidence.controls.accessControl,
    [string]$evidence.controls.restoreVerification
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedRenewalProven = $expectedOutcome -eq 'passed'
$expectedNextAction = if ([string]$evidence.execution.externalChangeStatus -eq 'failed') {
    'retry-or-escalate-retention-renewal'
}
elseif (
    [string]$evidence.controls.retentionPolicy -eq 'inactive' -or
    [string]$evidence.controls.objectLock -eq 'not-enforced' -or
    -not $retentionExtended -or
    -not $observedMeetsApprovedBoundary -or
    -not $observedCoversNextReview
) {
    'quarantine-and-repair-retention'
}
elseif ([string]$evidence.controls.archiveInventory -eq 'incomplete') {
    'restore-evidence-and-investigate'
}
elseif ([string]$evidence.controls.encryption -eq 'failed' -or [string]$evidence.controls.accessControl -eq 'overbroad') {
    'restrict-access-and-investigate'
}
elseif ([string]$evidence.controls.restoreVerification -eq 'failed') {
    'repair-archive-and-repeat-restore-test'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'establish-renewed-custody-review-baseline'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.approvedPlanVerified -ne $true -or
    [bool]$evidence.decision.originalCustodyPreserved -ne $true -or
    [bool]$evidence.decision.retentionRenewalProven -ne $expectedRenewalProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The production assurance retention-renewal outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    planSha256 = $planHash
    planIntegrityDigest = [string]$plan.integrityDigest
    approvalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$plan.changeId
    incidentId = [string]$plan.incidentId
    closureChangeId = [string]$plan.closureChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    rootCustodyEvidenceSha256 = [string]$plan.custody.sha256
    rootCustodyEvidenceIntegrityDigest = [string]$plan.custody.integrityDigest
    rootCustodyChainDigest = [string]$plan.custody.chainDigest
    custodyReviewChainDigest = [string]$plan.custody.reviewChainDigest
    custodyReviewHeadSequence = [int]$plan.custody.headReviewSequence
    currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
    requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
    observedRetentionUntilUtc = $observedRetentionUntil.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    minimumRemainingDaysAfterNextReview = $minimumRemainingDays
    remainingDaysAfterNextReview = $remainingDaysAfterNextReview
    retentionExtended = $retentionExtended
    observedMeetsApprovedBoundary = $observedMeetsApprovedBoundary
    observedCoversNextReview = $observedCoversNextReview
    approvedAtUtc = $approvedAt.ToString('o')
    executionCompletedAtUtc = $executionCompletedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    maxApprovedPlanAgeMinutes = [int]$evidence.execution.maxApprovedPlanAgeMinutes
    maxExecutionEvidenceAgeMinutes = [int]$evidence.execution.maxExecutionEvidenceAgeMinutes
    externalChangeStatus = [string]$evidence.execution.externalChangeStatus
    retentionPolicyStatus = [string]$evidence.controls.retentionPolicy
    objectLockStatus = [string]$evidence.controls.objectLock
    archiveInventoryStatus = [string]$evidence.controls.archiveInventory
    encryptionStatus = [string]$evidence.controls.encryption
    accessControlStatus = [string]$evidence.controls.accessControl
    restoreVerificationStatus = [string]$evidence.controls.restoreVerification
    externalChangeReference = [string]$evidence.externalEvidence.externalChangeReference
    retentionPolicyReference = [string]$evidence.externalEvidence.retentionPolicyReference
    objectLockReference = [string]$evidence.externalEvidence.objectLockReference
    archiveInventoryReference = [string]$evidence.externalEvidence.archiveInventoryReference
    encryptionReference = [string]$evidence.externalEvidence.encryptionReference
    accessReviewReference = [string]$evidence.externalEvidence.accessReviewReference
    restoreTestReference = [string]$evidence.externalEvidence.restoreTestReference
    executedBy = [string]$evidence.externalEvidence.executedBy
    verifiedBy = [string]$evidence.externalEvidence.verifiedBy
    renewalProven = $expectedRenewalProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance retention-renewal evidence integrity digest is invalid.'
}

Write-Host "Production assurance retention-renewal evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Observed retention: $($observedRetentionUntil.ToString('o')); renewal proven: $expectedRenewalProven"
Write-Host 'This validator is read-only and does not renew retention, alter archives, restore evidence, or change production.'
