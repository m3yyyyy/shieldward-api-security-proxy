[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ResumptionEvidencePath = '',
    [string]$PostIncidentEvidencePath = '',
    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [switch]$CheckCluster,
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production assurance continuity evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'scheduled-production-assurance-continuity'
) {
    throw 'The supplied production assurance continuity evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The assurance continuity evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The assurance continuity evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedResumptionPath = if ([string]::IsNullOrWhiteSpace($ResumptionEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.resumptionEvidence.relativePath) -Description 'Recorded resumption evidence path'
}
else {
    Resolve-LocalStatePath -Path $ResumptionEvidencePath -Description 'ResumptionEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedResumptionPath -PathType Leaf)) {
    throw "Recorded production assurance resumption evidence is missing: $resolvedResumptionPath"
}
$resumptionValidationArguments = @{
    EvidencePath = $resolvedResumptionPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'PostIncidentEvidencePath'; Value = $PostIncidentEvidencePath }
    [pscustomobject]@{ Name = 'ClosureEvidencePath'; Value = $ClosureEvidencePath }
    [pscustomobject]@{ Name = 'ClosurePlanPath'; Value = $ClosurePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $resumptionValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $resumptionValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-evidence.ps1') @resumptionValidationArguments 6>$null

$resumption = Get-Content -Raw -LiteralPath $resolvedResumptionPath | ConvertFrom-Json
$resumptionRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedResumptionPath).Replace('\', '/')
$resumptionHash = (Get-FileHash -LiteralPath $resolvedResumptionPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $resumptionRelativePath -ne [string]$evidence.resumptionEvidence.relativePath -or
    $resumptionHash -ne [string]$evidence.resumptionEvidence.sha256 -or
    [string]$resumption.integrityDigest -ne [string]$evidence.resumptionEvidence.integrityDigest -or
    ([DateTimeOffset]$resumption.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.resumptionEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.resumptionEvidence.outcome -ne 'passed' -or
    [bool]$evidence.resumptionEvidence.assuranceResumed -ne $true
) {
    throw 'The passed production assurance resumption evidence no longer matches continuity evidence.'
}
if (
    [string]$resumption.outcome -ne 'passed' -or
    [bool]$resumption.decision.assuranceResumed -ne $true -or
    [string]$resumption.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Scheduled assurance continuity evidence requires passed resumption evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$resumption.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$resumption.closureChangeId
) {
    throw 'The assurance continuity identity does not match resumption evidence.'
}
if (
    [string]$evidence.candidate.version -ne [string]$resumption.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$resumption.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$resumption.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$resumption.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$resumption.candidate.policyVersion
) {
    throw 'The assurance continuity candidate does not match resumption evidence.'
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
        throw "The assurance continuity evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.resumptionGateReference; Description = 'Resumption gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.scheduledReviewReference; Description = 'Scheduled review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.driftEvidenceReference; Description = 'Drift evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackRetentionReference; Description = 'Rollback retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$trafficMatchesResumption = [int]$evidence.traffic.observedPercent -eq [int]$resumption.traffic.observedPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [int]$resumption.traffic.observedPercent -ne 100 -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesResumption -ne $trafficMatchesResumption -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0
) {
    throw 'The assurance continuity traffic evidence is inconsistent with the resumption 100-percent boundary.'
}
if (
    [int]$evidence.rollback.targetPercent -ne [int]$resumption.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$resumption.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$resumption.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$resumption.rollback.procedureReference
) {
    throw 'The assurance continuity rollback evidence is inconsistent with resumption evidence.'
}

$resumptionCollectedAt = ([DateTimeOffset]$resumption.collectedAtUtc).ToUniversalTime()
$expectedDueAt = ([DateTimeOffset]$resumption.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = ([DateTimeOffset]$evidence.review.completedAtUtc).ToUniversalTime()
$recordedExpectedDueAt = ([DateTimeOffset]$evidence.review.expectedDueAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$reviewIntervalMinutes = [int]$resumption.schedule.reviewIntervalMinutes
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddMinutes(-5) -and
    $completedAt -le $expectedDueAt.AddMinutes([int]$evidence.review.completionGraceMinutes)
)
$resumptionAgeAtCollection = $collectedAt - $resumptionCollectedAt
$reviewAgeAtCollection = $collectedAt - $completedAt
if (
    [int]$evidence.review.sequence -ne 1 -or
    $recordedExpectedDueAt.ToString('o') -ne $expectedDueAt.ToString('o') -or
    [int]$evidence.review.completionGraceMinutes -lt 0 -or
    [int]$evidence.review.completionGraceMinutes -gt 120 -or
    [bool]$evidence.review.onTime -ne $reviewOnTime -or
    [int]$evidence.schedule.reviewIntervalMinutes -ne $reviewIntervalMinutes -or
    $nextReviewDueAt.ToString('o') -ne $completedAt.AddMinutes($reviewIntervalMinutes).ToString('o') -or
    [int]$evidence.review.maxResumptionEvidenceAgeHours -lt 1 -or
    [int]$evidence.review.maxResumptionEvidenceAgeHours -gt 2160 -or
    $resumptionAgeAtCollection.TotalHours -lt -1 -or
    $resumptionAgeAtCollection.TotalHours -gt [int]$evidence.review.maxResumptionEvidenceAgeHours -or
    [int]$evidence.review.maxReviewAgeMinutes -lt 5 -or
    [int]$evidence.review.maxReviewAgeMinutes -gt 1440 -or
    $reviewAgeAtCollection.TotalMinutes -lt -5 -or
    $reviewAgeAtCollection.TotalMinutes -gt [int]$evidence.review.maxReviewAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The scheduled assurance review timing, sequence, or freshness boundary is invalid.'
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
    -not $trafficMatchesResumption
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
    [bool]$evidence.decision.continuityProven -ne $expectedContinuityProven -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The scheduled assurance continuity outcome or action is inconsistent with recorded evidence.'
}

$integrity = [ordered]@{
    resumptionEvidenceSha256 = $resumptionHash
    resumptionEvidenceIntegrityDigest = [string]$resumption.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$resumption.incidentId
    closureChangeId = [string]$resumption.closureChangeId
    releaseVersion = [string]$resumption.candidate.version
    sourceTag = [string]$resumption.candidate.sourceTag
    controlPlaneImage = [string]$resumption.candidate.controlPlaneImage
    edgeImage = [string]$resumption.candidate.edgeImage
    policyVersion = [string]$resumption.candidate.policyVersion
    resumptionCollectedAtUtc = $resumptionCollectedAt.ToString('o')
    reviewSequence = [int]$evidence.review.sequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceMinutes = [int]$evidence.review.completionGraceMinutes
    reviewOnTime = $reviewOnTime
    reviewExecutionStatus = [string]$evidence.review.executionStatus
    collectedAtUtc = $collectedAt.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    reviewIntervalMinutes = $reviewIntervalMinutes
    maxResumptionEvidenceAgeHours = [int]$evidence.review.maxResumptionEvidenceAgeHours
    maxReviewAgeMinutes = [int]$evidence.review.maxReviewAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesResumption = $trafficMatchesResumption
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
    rollbackTargetPercent = [int]$resumption.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$resumption.rollback.emergencyTargetPercent
    resumptionGateReference = [string]$evidence.externalEvidence.resumptionGateReference
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
    throw 'The production assurance continuity evidence integrity digest is invalid.'
}

Write-Host "Scheduled production assurance continuity evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Review on time: $reviewOnTime; continuity proven: $expectedContinuityProven; next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not schedule reviews, change production, or remove rollback.'
