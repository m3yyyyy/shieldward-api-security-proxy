[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PreviousContinuityEvidencePath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [switch]$CheckCluster,
    [string]$ReferenceTimeUtc = '',
    [ValidateRange(0, 64)][int]$ChainDepth = 0
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

if ($ChainDepth -ge 64) {
    throw 'The recurring assurance chain exceeds the supported validation depth.'
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
    throw "Recurring production assurance evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'recurring-production-assurance-continuity'
) {
    throw 'The supplied recurring production assurance evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The recurring assurance evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The recurring assurance evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPreviousPath = if ([string]::IsNullOrWhiteSpace($PreviousContinuityEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.previousContinuityEvidence.relativePath) -Description 'Recorded previous continuity evidence path'
}
else {
    Resolve-LocalStatePath -Path $PreviousContinuityEvidencePath -Description 'PreviousContinuityEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Recorded previous production assurance continuity evidence is missing: $resolvedPreviousPath"
}
if ($resolvedPreviousPath.Equals($resolvedEvidencePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Recurring assurance evidence cannot reference itself as its previous review.'
}

$previous = Get-Content -Raw -LiteralPath $resolvedPreviousPath | ConvertFrom-Json
$previousType = [string]$previous.evidenceType
$previousValidationArguments = @{
    EvidencePath = $resolvedPreviousPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $previousValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
if ($previousType -eq 'scheduled-production-assurance-continuity') {
    & (Join-Path $PSScriptRoot 'test-production-assurance-continuity-evidence.ps1') @previousValidationArguments 6>$null
}
elseif ($previousType -eq 'recurring-production-assurance-continuity') {
    $previousValidationArguments.ChainDepth = $ChainDepth + 1
    & (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') @previousValidationArguments 6>$null
}
else {
    throw "Recorded previous continuity evidence type '$previousType' is unsupported."
}

$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $previousType -ne [string]$evidence.previousContinuityEvidence.evidenceType -or
    $previousRelativePath -ne [string]$evidence.previousContinuityEvidence.relativePath -or
    $previousHash -ne [string]$evidence.previousContinuityEvidence.sha256 -or
    [string]$previous.integrityDigest -ne [string]$evidence.previousContinuityEvidence.integrityDigest -or
    ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.previousContinuityEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$previous.review.sequence -ne [int]$evidence.previousContinuityEvidence.reviewSequence -or
    [string]$evidence.previousContinuityEvidence.outcome -ne 'passed' -or
    [bool]$evidence.previousContinuityEvidence.continuityProven -ne $true
) {
    throw 'The exact passed previous continuity evidence no longer matches the recurring assurance link.'
}
if (
    [string]$previous.outcome -ne 'passed' -or
    [bool]$previous.decision.monitoringContinues -ne $true -or
    [bool]$previous.decision.continuityProven -ne $true -or
    [string]$previous.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Recurring assurance requires a passed previous continuity review.'
}
if (
    [string]$evidence.incidentId -ne [string]$previous.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$previous.closureChangeId
) {
    throw 'The recurring assurance identity does not match previous continuity evidence.'
}
if (
    [string]$evidence.candidate.version -ne [string]$previous.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$previous.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$previous.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$previous.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$previous.candidate.policyVersion
) {
    throw 'The recurring assurance candidate does not match previous continuity evidence.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'review execution'; Actual = [string]$evidence.review.executionStatus; Allowed = @('completed', 'missed', 'unknown') }
    [pscustomobject]@{ Name = 'traffic enforcement'; Actual = [string]$evidence.traffic.enforcementStatus; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'assurance schedule'; Actual = [string]$evidence.schedule.status; Allowed = @('active', 'inactive', 'unknown') }
    [pscustomobject]@{ Name = 'monitoring coverage'; Actual = [string]$evidence.schedule.monitoringCoverage; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$evidence.signals.errorBudget; Allowed = @('within-budget', 'exhausted', 'unknown') }
    [pscustomobject]@{ Name = 'alerts'; Actual = [string]$evidence.signals.alerts; Allowed = @('clear', 'firing', 'unknown') }
    [pscustomobject]@{ Name = 'functional checks'; Actual = [string]$evidence.signals.functional; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$evidence.signals.dependencies; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$evidence.signals.operations; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'capacity'; Actual = [string]$evidence.signals.capacity; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'security'; Actual = [string]$evidence.signals.security; Allowed = @('clear', 'incident', 'unknown') }
    [pscustomobject]@{ Name = 'image drift'; Actual = [string]$evidence.drift.images; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'policy drift'; Actual = [string]$evidence.drift.policy; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'configuration drift'; Actual = [string]$evidence.drift.configuration; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'identity drift'; Actual = [string]$evidence.drift.identity; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'certificates'; Actual = [string]$evidence.drift.certificates; Allowed = @('healthy', 'expiring', 'invalid', 'unknown') }
    [pscustomobject]@{ Name = 'routing drift'; Actual = [string]$evidence.drift.routing; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'rollback retention'; Actual = [string]$evidence.rollback.retentionStatus; Allowed = @('retained', 'missing', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The recurring assurance evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.previousContinuityGateReference; Description = 'Previous continuity gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.scheduledReviewReference; Description = 'Scheduled review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.driftEvidenceReference; Description = 'Drift evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackRetentionReference; Description = 'Rollback retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$trafficMatchesPrevious = [int]$evidence.traffic.observedPercent -eq [int]$previous.traffic.observedPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [int]$previous.traffic.observedPercent -ne 100 -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesPrevious -ne $trafficMatchesPrevious -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0
) {
    throw 'The recurring assurance traffic evidence is inconsistent with the previous 100-percent boundary.'
}
if (
    [int]$evidence.rollback.targetPercent -ne [int]$previous.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$previous.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$previous.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$previous.rollback.procedureReference
) {
    throw 'The recurring assurance rollback evidence is inconsistent with previous continuity evidence.'
}

$previousCollectedAt = ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime()
$previousCompletedAt = ([DateTimeOffset]$previous.review.completedAtUtc).ToUniversalTime()
$expectedDueAt = ([DateTimeOffset]$previous.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
$recordedExpectedDueAt = ([DateTimeOffset]$evidence.review.expectedDueAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$reviewIntervalMinutes = [int]$previous.schedule.reviewIntervalMinutes
$expectedSequence = [int]$previous.review.sequence + 1
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddMinutes(-5) -and
    $completedAt -le $expectedDueAt.AddMinutes([int]$evidence.review.completionGraceMinutes)
)
$previousAgeAtCollection = $collectedAt - $previousCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    [int]$evidence.review.sequence -ne $expectedSequence -or
    [int]$evidence.review.previousSequence -ne [int]$previous.review.sequence -or
    $recordedExpectedDueAt.ToString('o') -ne $expectedDueAt.ToString('o') -or
    $completedAt -lt $previousCompletedAt -or
    [int]$evidence.review.completionGraceMinutes -lt 0 -or
    [int]$evidence.review.completionGraceMinutes -gt 120 -or
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    [int]$evidence.schedule.reviewIntervalMinutes -ne $reviewIntervalMinutes -or
    $nextReviewDueAt.ToString('o') -ne $completedAt.AddMinutes($reviewIntervalMinutes).ToString('o') -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -lt 1 -or
    [int]$evidence.review.maxPreviousEvidenceAgeHours -gt 2160 -or
    $previousAgeAtCollection.TotalHours -lt -1 -or
    $previousAgeAtCollection.TotalHours -gt [int]$evidence.review.maxPreviousEvidenceAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The recurring assurance review timing, sequence, or freshness boundary is invalid.'
}

$materialDriftDetected = @(
    [string]$evidence.drift.images,
    [string]$evidence.drift.policy,
    [string]$evidence.drift.configuration,
    [string]$evidence.drift.identity,
    [string]$evidence.drift.routing
) -contains 'detected'
$hasFailure = (
    [string]$evidence.review.executionStatus -eq 'missed' -or
    -not $reviewOnTime -or
    [string]$evidence.traffic.enforcementStatus -eq 'failed' -or
    [string]$evidence.schedule.status -eq 'inactive' -or
    [string]$evidence.schedule.monitoringCoverage -eq 'incomplete' -or
    [string]$evidence.signals.errorBudget -eq 'exhausted' -or
    [string]$evidence.signals.alerts -eq 'firing' -or
    [string]$evidence.signals.functional -eq 'failed' -or
    [string]$evidence.signals.dependencies -eq 'degraded' -or
    [string]$evidence.signals.operations -eq 'degraded' -or
    [string]$evidence.signals.capacity -eq 'degraded' -or
    [string]$evidence.signals.security -eq 'incident' -or
    $materialDriftDetected -or
    [string]$evidence.drift.certificates -in @('expiring', 'invalid') -or
    [string]$evidence.rollback.retentionStatus -eq 'missing' -or
    -not $trafficMatchesPrevious
)
$hasUnknown = @(
    [string]$evidence.review.executionStatus,
    [string]$evidence.traffic.enforcementStatus,
    [string]$evidence.schedule.status,
    [string]$evidence.schedule.monitoringCoverage,
    [string]$evidence.signals.errorBudget,
    [string]$evidence.signals.alerts,
    [string]$evidence.signals.functional,
    [string]$evidence.signals.dependencies,
    [string]$evidence.signals.operations,
    [string]$evidence.signals.capacity,
    [string]$evidence.signals.security,
    [string]$evidence.drift.images,
    [string]$evidence.drift.policy,
    [string]$evidence.drift.configuration,
    [string]$evidence.drift.identity,
    [string]$evidence.drift.certificates,
    [string]$evidence.drift.routing,
    [string]$evidence.rollback.retentionStatus
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedMonitoringContinues = (
    [string]$evidence.schedule.status -eq 'active' -and
    [string]$evidence.schedule.monitoringCoverage -eq 'complete'
)
$expectedContinuityProven = $expectedOutcome -eq 'passed'
$expectedNextAction = if ([string]$evidence.signals.security -eq 'incident' -or [string]$evidence.drift.certificates -eq 'invalid') {
    'disable-and-investigate'
}
elseif ($materialDriftDetected) {
    'reaccept-before-continuing'
}
elseif ([string]$evidence.drift.certificates -eq 'expiring') {
    'rotate-certificates-and-refresh-evidence'
}
elseif ([string]$evidence.review.executionStatus -eq 'missed' -or -not $reviewOnTime -or [string]$evidence.schedule.status -eq 'inactive') {
    'escalate-missed-assurance-review'
}
elseif ($expectedOutcome -eq 'failed') {
    'rollback-or-disable-and-investigate'
}
elseif ($expectedOutcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.monitoringContinues -ne $expectedMonitoringContinues -or
    [bool]$evidence.decision.continuityLinkValid -ne $true -or
    [bool]$evidence.decision.continuityProven -ne $expectedContinuityProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The recurring assurance continuity outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    previousContinuityEvidenceType = $previousType
    previousContinuityEvidenceSha256 = $previousHash
    previousContinuityEvidenceIntegrityDigest = [string]$previous.integrityDigest
    previousReviewSequence = [int]$previous.review.sequence
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    releaseVersion = [string]$previous.candidate.version
    sourceTag = [string]$previous.candidate.sourceTag
    controlPlaneImage = [string]$previous.candidate.controlPlaneImage
    edgeImage = [string]$previous.candidate.edgeImage
    policyVersion = [string]$previous.candidate.policyVersion
    previousCollectedAtUtc = $previousCollectedAt.ToString('o')
    reviewSequence = $expectedSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceMinutes = [int]$evidence.review.completionGraceMinutes
    reviewOnTime = $reviewOnTime
    reviewExecutionStatus = [string]$evidence.review.executionStatus
    collectedAtUtc = $collectedAt.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    reviewIntervalMinutes = $reviewIntervalMinutes
    maxPreviousEvidenceAgeHours = [int]$evidence.review.maxPreviousEvidenceAgeHours
    maxReviewAgeMinutes = [int]$evidence.review.maxReviewAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesPrevious = $trafficMatchesPrevious
    trafficEnforcementStatus = [string]$evidence.traffic.enforcementStatus
    assuranceScheduleStatus = [string]$evidence.schedule.status
    monitoringCoverageStatus = [string]$evidence.schedule.monitoringCoverage
    errorBudgetStatus = [string]$evidence.signals.errorBudget
    alertStatus = [string]$evidence.signals.alerts
    functionalStatus = [string]$evidence.signals.functional
    dependencyStatus = [string]$evidence.signals.dependencies
    operationalStatus = [string]$evidence.signals.operations
    capacityStatus = [string]$evidence.signals.capacity
    securityStatus = [string]$evidence.signals.security
    imageDriftStatus = [string]$evidence.drift.images
    policyDriftStatus = [string]$evidence.drift.policy
    configurationDriftStatus = [string]$evidence.drift.configuration
    identityDriftStatus = [string]$evidence.drift.identity
    certificateStatus = [string]$evidence.drift.certificates
    routingDriftStatus = [string]$evidence.drift.routing
    rollbackRetentionStatus = [string]$evidence.rollback.retentionStatus
    rollbackTargetPercent = [int]$previous.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$previous.rollback.emergencyTargetPercent
    previousContinuityGateReference = [string]$evidence.externalEvidence.previousContinuityGateReference
    scheduledReviewReference = [string]$evidence.externalEvidence.scheduledReviewReference
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    monitoringEvidenceReference = [string]$evidence.externalEvidence.monitoringEvidenceReference
    driftEvidenceReference = [string]$evidence.externalEvidence.driftEvidenceReference
    rollbackRetentionReference = [string]$evidence.externalEvidence.rollbackRetentionReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    monitoringContinues = $expectedMonitoringContinues
    continuityProven = $expectedContinuityProven
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The recurring production assurance evidence integrity digest is invalid.'
}

Write-Host "Recurring production assurance evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Review sequence $expectedSequence linked to sequence $($previous.review.sequence); continuity proven: $expectedContinuityProven"
Write-Host 'This validator is read-only and does not schedule reviews, change production, or remove rollback.'
