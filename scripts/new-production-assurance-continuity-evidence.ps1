[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResumptionEvidencePath,
    [string]$PostIncidentEvidencePath = '',
    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ReviewCompletedAtUtc,
    [ValidateRange(1, 1)][int]$ReviewSequence = 1,
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

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResumptionGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScheduledReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TrafficStateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MonitoringEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DriftEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RollbackRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReviewedBy,

    [ValidateRange(1, 2160)][int]$MaxResumptionEvidenceAgeHours = 168,
    [ValidateRange(5, 1440)][int]$MaxReviewAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-continuity',
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
    [pscustomobject]@{ Value = $ResumptionGateReference; Description = 'ResumptionGateReference' }
    [pscustomobject]@{ Value = $ScheduledReviewReference; Description = 'ScheduledReviewReference' }
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $DriftEvidenceReference; Description = 'DriftEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackRetentionReference; Description = 'RollbackRetentionReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedResumptionPath = Resolve-LocalStatePath -Path $ResumptionEvidencePath -Description 'ResumptionEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedResumptionPath -PathType Leaf)) {
    throw "Production assurance resumption evidence is missing: $resolvedResumptionPath"
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
if (
    [string]$resumption.outcome -ne 'passed' -or
    [bool]$resumption.decision.assuranceResumed -ne $true -or
    [string]$resumption.schedule.status -ne 'active' -or
    [string]$resumption.schedule.monitoringCoverage -ne 'complete' -or
    [int]$resumption.traffic.observedPercent -ne 100 -or
    [int]$resumption.traffic.mutationPercentagePoints -ne 0 -or
    [string]$resumption.rollback.retentionStatus -ne 'retained' -or
    [string]$resumption.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Scheduled assurance continuity requires passed continuous assurance resumption evidence.'
}

$expectedDueAt = ([DateTimeOffset]$resumption.schedule.nextReviewDueAtUtc).ToUniversalTime()
$completedAt = $ReviewCompletedAtUtc.ToUniversalTime()
$resumptionCollectedAt = ([DateTimeOffset]$resumption.collectedAtUtc).ToUniversalTime()
$resumptionAge = $referenceNow - $resumptionCollectedAt
$reviewAge = $referenceNow - $completedAt
if (
    $completedAt -lt $resumptionCollectedAt -or
    $resumptionAge.TotalHours -lt -1 -or
    $resumptionAge.TotalHours -gt $MaxResumptionEvidenceAgeHours -or
    $reviewAge.TotalMinutes -lt -5 -or
    $reviewAge.TotalMinutes -gt $MaxReviewAgeMinutes
) {
    throw 'Scheduled assurance review evidence must follow resumption and use current freshness-bounded observations.'
}
$reviewOnTime = (
    $completedAt -ge $expectedDueAt.AddMinutes(-5) -and
    $completedAt -le $expectedDueAt.AddMinutes($CompletionGraceMinutes)
)

$trafficMatchesResumption = $ObservedTrafficPercent -eq [int]$resumption.traffic.observedPercent
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
    -not $trafficMatchesResumption
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
$reviewIntervalMinutes = [int]$resumption.schedule.reviewIntervalMinutes
$nextReviewDueAt = $completedAt.AddMinutes($reviewIntervalMinutes)
$resumptionHash = (Get-FileHash -LiteralPath $resolvedResumptionPath -Algorithm SHA256).Hash.ToLowerInvariant()
$resumptionRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedResumptionPath).Replace('\', '/')
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
    reviewSequence = $ReviewSequence
    expectedDueAtUtc = $expectedDueAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    completionGraceMinutes = $CompletionGraceMinutes
    reviewOnTime = $reviewOnTime
    reviewExecutionStatus = $ReviewExecutionStatus
    collectedAtUtc = $collectedAt.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    reviewIntervalMinutes = $reviewIntervalMinutes
    maxResumptionEvidenceAgeHours = $MaxResumptionEvidenceAgeHours
    maxReviewAgeMinutes = $MaxReviewAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesResumption = $trafficMatchesResumption
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
    rollbackTargetPercent = [int]$resumption.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$resumption.rollback.emergencyTargetPercent
    resumptionGateReference = $ResumptionGateReference
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
    evidenceType = 'scheduled-production-assurance-continuity'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$resumption.incidentId
    closureChangeId = [string]$resumption.closureChangeId
    resumptionEvidence = [ordered]@{
        relativePath = $resumptionRelativePath
        sha256 = $resumptionHash
        integrityDigest = [string]$resumption.integrityDigest
        collectedAtUtc = $resumptionCollectedAt.ToString('o')
        outcome = [string]$resumption.outcome
        assuranceResumed = [bool]$resumption.decision.assuranceResumed
    }
    candidate = [ordered]@{
        version = [string]$resumption.candidate.version
        sourceTag = [string]$resumption.candidate.sourceTag
        controlPlaneImage = [string]$resumption.candidate.controlPlaneImage
        edgeImage = [string]$resumption.candidate.edgeImage
        policyVersion = [string]$resumption.candidate.policyVersion
    }
    review = [ordered]@{
        sequence = $ReviewSequence
        executionStatus = $ReviewExecutionStatus
        expectedDueAtUtc = $expectedDueAt.ToString('o')
        completedAtUtc = $completedAt.ToString('o')
        completionGraceMinutes = $CompletionGraceMinutes
        onTime = $reviewOnTime
        maxResumptionEvidenceAgeHours = $MaxResumptionEvidenceAgeHours
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
        matchesResumption = $trafficMatchesResumption
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
        targetPercent = [int]$resumption.rollback.targetPercent
        emergencyTargetPercent = [int]$resumption.rollback.emergencyTargetPercent
        authority = [string]$resumption.rollback.authority
        procedureReference = [string]$resumption.rollback.procedureReference
        retentionStatus = $RollbackRetentionStatus
    }
    externalEvidence = [ordered]@{
        resumptionGateReference = $ResumptionGateReference
        scheduledReviewReference = $ScheduledReviewReference
        trafficStateReference = $TrafficStateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        driftEvidenceReference = $DriftEvidenceReference
        rollbackRetentionReference = $RollbackRetentionReference
        reviewedBy = $ReviewedBy
    }
    decision = [ordered]@{
        monitoringContinues = $monitoringContinues
        continuityProven = $continuityProven
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'continuity-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance continuity evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Scheduled production assurance continuity evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Review on time: $reviewOnTime; continuity proven: $continuityProven; next action: $nextAction"
Write-Host 'No scheduler, cluster, traffic, incident, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Scheduled assurance continuity is not proven. Preserve rollback and follow the recorded action.'
}
