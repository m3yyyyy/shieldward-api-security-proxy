[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousContinuityEvidencePath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ReviewCompletedAtUtc,
    [ValidateRange(0, 120)][int]$CompletionGraceMinutes = 15,
    [Parameter(Mandatory)][ValidateRange(100, 100)][int]$ObservedTrafficPercent,

    [Parameter(Mandatory)][ValidateSet('completed', 'missed', 'unknown')][string]$ReviewExecutionStatus,
    [Parameter(Mandatory)][ValidateSet('confirmed', 'failed', 'unknown')][string]$TrafficEnforcementStatus,
    [Parameter(Mandatory)][ValidateSet('active', 'inactive', 'unknown')][string]$AssuranceScheduleStatus,
    [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'unknown')][string]$MonitoringCoverageStatus,
    [Parameter(Mandatory)][ValidateSet('within-budget', 'exhausted', 'unknown')][string]$ErrorBudgetStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'firing', 'unknown')][string]$AlertStatus,
    [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'unknown')][string]$FunctionalStatus,
    [Parameter(Mandatory)][ValidateSet('healthy', 'degraded', 'unknown')][string]$DependencyStatus,
    [Parameter(Mandatory)][ValidateSet('healthy', 'degraded', 'unknown')][string]$OperationalStatus,
    [Parameter(Mandatory)][ValidateSet('healthy', 'degraded', 'unknown')][string]$CapacityStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'incident', 'unknown')][string]$SecurityStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'detected', 'unknown')][string]$ImageDriftStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'detected', 'unknown')][string]$PolicyDriftStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'detected', 'unknown')][string]$ConfigurationDriftStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'detected', 'unknown')][string]$IdentityDriftStatus,
    [Parameter(Mandatory)][ValidateSet('healthy', 'expiring', 'invalid', 'unknown')][string]$CertificateStatus,
    [Parameter(Mandatory)][ValidateSet('clear', 'detected', 'unknown')][string]$RoutingDriftStatus,
    [Parameter(Mandatory)][ValidateSet('retained', 'missing', 'unknown')][string]$RollbackRetentionStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreviousContinuityGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScheduledReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TrafficStateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MonitoringEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DriftEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RollbackRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReviewedBy,

    [ValidateRange(1, 2160)][int]$MaxPreviousEvidenceAgeHours = 168,
    [ValidateRange(5, 1440)][int]$MaxReviewAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-recurring',
    [switch]$CheckCluster,
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

foreach ($reference in @(
    [pscustomobject]@{ Value = $PreviousContinuityGateReference; Description = 'PreviousContinuityGateReference' }
    [pscustomobject]@{ Value = $ScheduledReviewReference; Description = 'ScheduledReviewReference' }
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $DriftEvidenceReference; Description = 'DriftEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackRetentionReference; Description = 'RollbackRetentionReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPreviousPath = Resolve-LocalStatePath -Path $PreviousContinuityEvidencePath -Description 'PreviousContinuityEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedPreviousPath -PathType Leaf)) {
    throw "Previous production assurance continuity evidence is missing: $resolvedPreviousPath"
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
    & (Join-Path $PSScriptRoot 'test-production-assurance-recurring-evidence.ps1') @previousValidationArguments 6>$null
}
else {
    throw "Previous continuity evidence type '$previousType' is unsupported."
}

if (
    [string]$previous.outcome -ne 'passed' -or
    [bool]$previous.decision.monitoringContinues -ne $true -or
    [bool]$previous.decision.continuityProven -ne $true -or
    [string]$previous.schedule.status -ne 'active' -or
    [string]$previous.schedule.monitoringCoverage -ne 'complete' -or
    [int]$previous.traffic.observedPercent -ne 100 -or
    [int]$previous.traffic.mutationPercentagePoints -ne 0 -or
    [string]$previous.rollback.retentionStatus -ne 'retained' -or
    [string]$previous.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Recurring assurance requires exact passed previous continuity evidence.'
}

$expectedDueAt = ([DateTimeOffset]$previous.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = $ReviewCompletedAtUtc.ToUniversalTime()
$previousCollectedAt = ([DateTimeOffset]$previous.collectedAtUtc).ToUniversalTime()
$previousCompletedAt = ([DateTimeOffset]$previous.review.completedAtUtc).ToUniversalTime()
$previousAge = $referenceNow - $previousCollectedAt
$reviewAge = $referenceNow - $completedAt
if (
    $completedAt -lt $previousCompletedAt -or
    $previousAge.TotalHours -lt -1 -or
    $previousAge.TotalHours -gt $MaxPreviousEvidenceAgeHours -or
    $reviewAge.TotalMinutes -lt -5 -or
    $reviewAge.TotalMinutes -gt $MaxReviewAgeMinutes
) {
    throw 'Recurring assurance review evidence must follow the previous review and use current freshness-bounded observations.'
}
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddMinutes(-5) -and
    $completedAt -le $expectedDueAt.AddMinutes($CompletionGraceMinutes)
)

$trafficMatchesPrevious = $ObservedTrafficPercent -eq [int]$previous.traffic.observedPercent
$materialDriftDetected = @(
    $ImageDriftStatus,
    $PolicyDriftStatus,
    $ConfigurationDriftStatus,
    $IdentityDriftStatus,
    $RoutingDriftStatus
) -contains 'detected'
$hasFailure = (
    $ReviewExecutionStatus -eq 'missed' -or
    -not $reviewOnTime -or
    $TrafficEnforcementStatus -eq 'failed' -or
    $AssuranceScheduleStatus -eq 'inactive' -or
    $MonitoringCoverageStatus -eq 'incomplete' -or
    $ErrorBudgetStatus -eq 'exhausted' -or
    $AlertStatus -eq 'firing' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident' -or
    $materialDriftDetected -or
    $CertificateStatus -in @('expiring', 'invalid') -or
    $RollbackRetentionStatus -eq 'missing' -or
    -not $trafficMatchesPrevious
)
$hasUnknown = @(
    $ReviewExecutionStatus,
    $TrafficEnforcementStatus,
    $AssuranceScheduleStatus,
    $MonitoringCoverageStatus,
    $ErrorBudgetStatus,
    $AlertStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus,
    $CapacityStatus,
    $SecurityStatus,
    $ImageDriftStatus,
    $PolicyDriftStatus,
    $ConfigurationDriftStatus,
    $IdentityDriftStatus,
    $CertificateStatus,
    $RoutingDriftStatus,
    $RollbackRetentionStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$monitoringContinues = $AssuranceScheduleStatus -eq 'active' -and $MonitoringCoverageStatus -eq 'complete'
$continuityProven = $outcome -eq 'passed'
$nextAction = if ($SecurityStatus -eq 'incident' -or $CertificateStatus -eq 'invalid') {
    'disable-and-investigate'
}
elseif ($materialDriftDetected) {
    'reaccept-before-continuing'
}
elseif ($CertificateStatus -eq 'expiring') {
    'rotate-certificates-and-refresh-evidence'
}
elseif ($ReviewExecutionStatus -eq 'missed' -or -not $reviewOnTime -or $AssuranceScheduleStatus -eq 'inactive') {
    'escalate-missed-assurance-review'
}
elseif ($outcome -eq 'failed') {
    'rollback-or-disable-and-investigate'
}
elseif ($outcome -eq 'unknown') {
    'investigate-and-refresh-evidence'
}
else {
    'continue-scheduled-production-assurance'
}

$collectedAt = $referenceNow
$reviewIntervalMinutes = [int]$previous.schedule.reviewIntervalMinutes
$nextReviewDueAt = $completedAt.AddMinutes($reviewIntervalMinutes)
$reviewSequence = [int]$previous.review.sequence + 1
$previousHash = (Get-FileHash -LiteralPath $resolvedPreviousPath -Algorithm SHA256).Hash.ToLowerInvariant()
$previousRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPreviousPath).Replace('\', '/')
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
    reviewSequence = $reviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceMinutes = $CompletionGraceMinutes
    reviewOnTime = $reviewOnTime
    reviewExecutionStatus = $ReviewExecutionStatus
    collectedAtUtc = $collectedAt.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    reviewIntervalMinutes = $reviewIntervalMinutes
    maxPreviousEvidenceAgeHours = $MaxPreviousEvidenceAgeHours
    maxReviewAgeMinutes = $MaxReviewAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPrevious = $trafficMatchesPrevious
    trafficEnforcementStatus = $TrafficEnforcementStatus
    assuranceScheduleStatus = $AssuranceScheduleStatus
    monitoringCoverageStatus = $MonitoringCoverageStatus
    errorBudgetStatus = $ErrorBudgetStatus
    alertStatus = $AlertStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    capacityStatus = $CapacityStatus
    securityStatus = $SecurityStatus
    imageDriftStatus = $ImageDriftStatus
    policyDriftStatus = $PolicyDriftStatus
    configurationDriftStatus = $ConfigurationDriftStatus
    identityDriftStatus = $IdentityDriftStatus
    certificateStatus = $CertificateStatus
    routingDriftStatus = $RoutingDriftStatus
    rollbackRetentionStatus = $RollbackRetentionStatus
    rollbackTargetPercent = [int]$previous.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$previous.rollback.emergencyTargetPercent
    previousContinuityGateReference = $PreviousContinuityGateReference
    scheduledReviewReference = $ScheduledReviewReference
    trafficStateReference = $TrafficStateReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    driftEvidenceReference = $DriftEvidenceReference
    rollbackRetentionReference = $RollbackRetentionReference
    reviewedBy = $ReviewedBy
    monitoringContinues = $monitoringContinues
    continuityProven = $continuityProven
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'recurring-production-assurance-continuity'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$previous.incidentId
    closureChangeId = [string]$previous.closureChangeId
    previousContinuityEvidence = [ordered]@{
        evidenceType = $previousType
        relativePath = $previousRelativePath
        sha256 = $previousHash
        integrityDigest = [string]$previous.integrityDigest
        collectedAtUtc = $previousCollectedAt.ToString('o')
        reviewSequence = [int]$previous.review.sequence
        outcome = [string]$previous.outcome
        continuityProven = [bool]$previous.decision.continuityProven
    }
    candidate = [ordered]@{
        version = [string]$previous.candidate.version
        sourceTag = [string]$previous.candidate.sourceTag
        controlPlaneImage = [string]$previous.candidate.controlPlaneImage
        edgeImage = [string]$previous.candidate.edgeImage
        policyVersion = [string]$previous.candidate.policyVersion
    }
    review = [ordered]@{
        sequence = $reviewSequence
        previousSequence = [int]$previous.review.sequence
        executionStatus = $ReviewExecutionStatus
        expectedDueAtUtc = $expectedDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceMinutes = $CompletionGraceMinutes
        onTime = $reviewOnTime
        maxPreviousEvidenceAgeHours = $MaxPreviousEvidenceAgeHours
        maxReviewAgeMinutes = $MaxReviewAgeMinutes
    }
    schedule = [ordered]@{
        status = $AssuranceScheduleStatus
        monitoringCoverage = $MonitoringCoverageStatus
        reviewIntervalMinutes = $reviewIntervalMinutes
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    }
    traffic = [ordered]@{
        expectedPercent = 100
        observedPercent = $ObservedTrafficPercent
        matchesPrevious = $trafficMatchesPrevious
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
        mutationPercentagePoints = 0
    }
    signals = [ordered]@{
        errorBudget = $ErrorBudgetStatus
        alerts = $AlertStatus
        functional = $FunctionalStatus
        dependencies = $DependencyStatus
        operations = $OperationalStatus
        capacity = $CapacityStatus
        security = $SecurityStatus
    }
    drift = [ordered]@{
        images = $ImageDriftStatus
        policy = $PolicyDriftStatus
        configuration = $ConfigurationDriftStatus
        identity = $IdentityDriftStatus
        certificates = $CertificateStatus
        routing = $RoutingDriftStatus
    }
    rollback = [ordered]@{
        targetPercent = [int]$previous.rollback.targetPercent
        emergencyTargetPercent = [int]$previous.rollback.emergencyTargetPercent
        authority = [string]$previous.rollback.authority
        procedureReference = [string]$previous.rollback.procedureReference
        retentionStatus = $RollbackRetentionStatus
    }
    externalEvidence = [ordered]@{
        previousContinuityGateReference = $PreviousContinuityGateReference
        scheduledReviewReference = $ScheduledReviewReference
        trafficStateReference = $TrafficStateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        driftEvidenceReference = $DriftEvidenceReference
        rollbackRetentionReference = $RollbackRetentionReference
        reviewedBy = $ReviewedBy
    }
    decision = [ordered]@{
        monitoringContinues = $monitoringContinues
        continuityLinkValid = $true
        continuityProven = $continuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'review-{0}-sequence-{1}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $reviewSequence
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Recurring production assurance evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Recurring production assurance evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review sequence $reviewSequence on time: $reviewOnTime; continuity proven: $continuityProven; next action: $nextAction"
Write-Host 'No scheduler, cluster, traffic, incident, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Recurring assurance continuity is not proven. Preserve rollback and follow the recorded action.'
}
