[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ExecutionCompletedAtUtc,
    [Parameter(Mandatory)][DateTimeOffset]$ObservedRetentionUntilUtc,
    [Parameter(Mandatory)][ValidateSet('completed', 'failed', 'unknown')][string]$ExternalChangeStatus,
    [Parameter(Mandatory)][ValidateSet('active', 'inactive', 'unknown')][string]$RetentionPolicyStatus,
    [Parameter(Mandatory)][ValidateSet('enforced', 'not-enforced', 'unknown')][string]$ObjectLockStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$ArchiveInventoryStatus,
    [Parameter(Mandatory)][ValidateSet('verified', 'failed', 'unknown')][string]$EncryptionStatus,
    [Parameter(Mandatory)][ValidateSet('least-privilege', 'overbroad', 'unknown')][string]$AccessControlStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$RestoreVerificationStatus,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExternalChangeReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RetentionPolicyReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ObjectLockReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArchiveInventoryReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EncryptionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccessReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RestoreTestReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExecutedBy,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VerifiedBy,
    [ValidateRange(5, 1440)][int]$MaxApprovedPlanAgeMinutes = 60,
    [ValidateRange(5, 1440)][int]$MaxExecutionEvidenceAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-generation-4-retention-renewal-evidence',
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
    $resolved = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path)) }
    if (-not $resolved.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be beneath the ignored .shieldward directory."
    }
    return $resolved
}

function Assert-Reference {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Description)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 256 -or $Value -match '[\x00-\x1f]' -or $Value -match '(?i)REPLACE') {
        throw "$Description must be a non-placeholder value of at most 256 characters without control characters."
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha256.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

foreach ($reference in @(
    [pscustomobject]@{ Value = $ExternalChangeReference; Description = 'ExternalChangeReference' }
    [pscustomobject]@{ Value = $RetentionPolicyReference; Description = 'RetentionPolicyReference' }
    [pscustomobject]@{ Value = $ObjectLockReference; Description = 'ObjectLockReference' }
    [pscustomobject]@{ Value = $ArchiveInventoryReference; Description = 'ArchiveInventoryReference' }
    [pscustomobject]@{ Value = $EncryptionReference; Description = 'EncryptionReference' }
    [pscustomobject]@{ Value = $AccessReviewReference; Description = 'AccessReviewReference' }
    [pscustomobject]@{ Value = $RestoreTestReference; Description = 'RestoreTestReference' }
    [pscustomobject]@{ Value = $ExecutedBy; Description = 'ExecutedBy' }
    [pscustomobject]@{ Value = $VerifiedBy; Description = 'VerifiedBy' }
)) { Assert-Reference -Value $reference.Value -Description $reference.Description }

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') { throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.' }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Approved renewed retention-renewal plan is missing: $resolvedPlanPath"
}
$planGateArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    MaxPlanAgeMinutes = $MaxApprovedPlanAgeMinutes
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) { $planGateArguments.ReferenceTimeUtc = $ReferenceTimeUtc }
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-4-retention-renewal-gate.ps1') @planGateArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$executionCompletedAt = $ExecutionCompletedAtUtc.ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$plan.renewal.currentRetentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$observedRetentionUntil = $ObservedRetentionUntilUtc.ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime()
$minimumRemainingDays = [int]$plan.renewal.minimumRemainingDaysAfterNextReview
$executionAge = $referenceNow - $executionCompletedAt
if (
    $executionCompletedAt -lt $approvedAt -or
    $executionCompletedAt -ge $currentRetentionUntil -or
    $executionAge.TotalMinutes -lt -5 -or
    $executionAge.TotalMinutes -gt $MaxExecutionEvidenceAgeMinutes
) {
    throw 'Renewed retention execution must follow approval, precede existing expiry, and remain fresh.'
}

$retentionExtended = $observedRetentionUntil -gt $currentRetentionUntil
$observedMeetsApprovedBoundary = $observedRetentionUntil -ge $requestedRetentionUntil
$remainingDaysAfterNextReview = [math]::Round(($observedRetentionUntil - $nextReviewDueAt).TotalDays, 6)
$observedCoversNextReview = $remainingDaysAfterNextReview -ge $minimumRemainingDays
$hasFailure = (
    $ExternalChangeStatus -eq 'failed' -or $RetentionPolicyStatus -eq 'inactive' -or
    $ObjectLockStatus -eq 'not-enforced' -or $ArchiveInventoryStatus -eq 'incomplete' -or
    $EncryptionStatus -eq 'failed' -or $AccessControlStatus -eq 'overbroad' -or
    $RestoreVerificationStatus -eq 'failed' -or -not $retentionExtended -or
    -not $observedMeetsApprovedBoundary -or -not $observedCoversNextReview
)
$hasUnknown = @($ExternalChangeStatus,$RetentionPolicyStatus,$ObjectLockStatus,$ArchiveInventoryStatus,$EncryptionStatus,$AccessControlStatus,$RestoreVerificationStatus) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$renewalProven = $outcome -eq 'passed'
$nextAction = if ($ExternalChangeStatus -eq 'failed') {
    'retry-or-escalate-generation-4-retention-renewal'
}
elseif ($RetentionPolicyStatus -eq 'inactive' -or $ObjectLockStatus -eq 'not-enforced' -or -not $retentionExtended -or -not $observedMeetsApprovedBoundary -or -not $observedCoversNextReview) {
    'quarantine-and-repair-generation-4-retention'
}
elseif ($ArchiveInventoryStatus -eq 'incomplete') { 'restore-evidence-and-investigate' }
elseif ($EncryptionStatus -eq 'failed' -or $AccessControlStatus -eq 'overbroad') { 'restrict-access-and-investigate' }
elseif ($RestoreVerificationStatus -eq 'failed') { 'repair-archive-and-repeat-restore-test' }
elseif ($outcome -eq 'unknown') { 'investigate-and-refresh-evidence' }
else { 'establish-generation-5-custody-review-baseline' }

$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$collectedAt = $referenceNow
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
    generation4BaselineSha256 = [string]$plan.lineage.generation4BaselineSha256
    generation4BaselineIntegrityDigest = [string]$plan.lineage.generation4BaselineIntegrityDigest
    generation4LineageDigest = [string]$plan.lineage.generation4LineageDigest
    previousRenewalEvidenceSha256 = [string]$plan.lineage.previousRenewalEvidenceSha256
    previousRenewalEvidenceIntegrityDigest = [string]$plan.lineage.previousRenewalEvidenceIntegrityDigest
    inheritedLineageDigest = Get-Sha256Text -Text ($plan.lineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress)
    generation4ReviewChainDigest = [string]$plan.lineage.generation4ReviewChainDigest
    generation4ReviewHeadSequence = [int]$plan.lineage.generation4ReviewHeadSequence
    currentBaselineGeneration = [int]$plan.renewal.currentBaselineGeneration
    nextBaselineGeneration = [int]$plan.renewal.nextBaselineGeneration
    currentRenewalSequence = [int]$plan.renewal.currentRenewalSequence
    renewalSequence = [int]$plan.renewal.renewalSequence
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
    maxApprovedPlanAgeMinutes = $MaxApprovedPlanAgeMinutes
    maxExecutionEvidenceAgeMinutes = $MaxExecutionEvidenceAgeMinutes
    externalChangeStatus = $ExternalChangeStatus
    retentionPolicyStatus = $RetentionPolicyStatus
    objectLockStatus = $ObjectLockStatus
    archiveInventoryStatus = $ArchiveInventoryStatus
    encryptionStatus = $EncryptionStatus
    accessControlStatus = $AccessControlStatus
    restoreVerificationStatus = $RestoreVerificationStatus
    externalChangeReference = $ExternalChangeReference
    retentionPolicyReference = $RetentionPolicyReference
    objectLockReference = $ObjectLockReference
    archiveInventoryReference = $ArchiveInventoryReference
    encryptionReference = $EncryptionReference
    accessReviewReference = $AccessReviewReference
    restoreTestReference = $RestoreTestReference
    executedBy = $ExecutedBy
    verifiedBy = $VerifiedBy
    lineagePreserved = $true
    renewalProven = $renewalProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'production-assurance-generation-4-retention-renewal-evidence'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = [string]$plan.changeId
    incidentId = [string]$plan.incidentId
    closureChangeId = [string]$plan.closureChangeId
    candidate = $plan.candidate
    approvedPlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        approvedAtUtc = $approvedAt.ToString('o')
        state = [string]$plan.state
        nextAction = [string]$plan.decision.nextAction
    }
    lineage = $plan.lineage
    renewal = [ordered]@{
        method = [string]$plan.renewal.method
        currentBaselineGeneration = [int]$plan.renewal.currentBaselineGeneration
        nextBaselineGeneration = [int]$plan.renewal.nextBaselineGeneration
        currentRenewalSequence = [int]$plan.renewal.currentRenewalSequence
        renewalSequence = [int]$plan.renewal.renewalSequence
        currentRetentionUntilUtc = $currentRetentionUntil.ToString('o')
        requestedRetentionUntilUtc = $requestedRetentionUntil.ToString('o')
        observedRetentionUntilUtc = $observedRetentionUntil.ToString('o')
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        minimumRemainingDaysAfterNextReview = $minimumRemainingDays
        remainingDaysAfterNextReview = $remainingDaysAfterNextReview
        retentionExtended = $retentionExtended
        observedMeetsApprovedBoundary = $observedMeetsApprovedBoundary
        observedCoversNextReview = $observedCoversNextReview
        archiveLocationReference = [string]$plan.renewal.archiveLocationReference
    }
    execution = [ordered]@{
        completedAtUtc = $executionCompletedAt.ToString('o')
        maxApprovedPlanAgeMinutes = $MaxApprovedPlanAgeMinutes
        maxExecutionEvidenceAgeMinutes = $MaxExecutionEvidenceAgeMinutes
        externalChangeStatus = $ExternalChangeStatus
    }
    controls = [ordered]@{
        retentionPolicy = $RetentionPolicyStatus
        objectLock = $ObjectLockStatus
        archiveInventory = $ArchiveInventoryStatus
        encryption = $EncryptionStatus
        accessControl = $AccessControlStatus
        restoreVerification = $RestoreVerificationStatus
    }
    externalEvidence = [ordered]@{
        externalChangeReference = $ExternalChangeReference
        retentionPolicyReference = $RetentionPolicyReference
        objectLockReference = $ObjectLockReference
        archiveInventoryReference = $ArchiveInventoryReference
        encryptionReference = $EncryptionReference
        accessReviewReference = $AccessReviewReference
        restoreTestReference = $RestoreTestReference
        executedBy = $ExecutedBy
        verifiedBy = $VerifiedBy
    }
    decision = [ordered]@{
        approvedPlanVerified = $true
        lineagePreserved = $true
        retentionRenewalProven = $renewalProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$safeChangeId = ([string]$plan.changeId) -replace '[^A-Za-z0-9._-]', '-'
$fileName = 'generation-4-retention-renewal-evidence-{0}-{1}.json' -f $safeChangeId, $collectedAt.ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Generation-4 production assurance retention-renewal evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText($evidencePath,(($evidence | ConvertTo-Json -Depth 9)+[Environment]::NewLine),[System.Text.UTF8Encoding]::new($false))

Write-Host "Generation-4 production assurance retention-renewal evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Observed retention through $($observedRetentionUntil.ToString('o')); next action: $nextAction"
Write-Host 'No archive, object-lock, retention, access, restore, scheduler, cluster, traffic, or rollback changes were made.'
if ($outcome -ne 'passed') { Write-Warning 'Renewed retention execution was not proven. Preserve evidence and follow the recorded action.' }

