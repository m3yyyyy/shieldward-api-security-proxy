[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PostIncidentEvidencePath,
    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][DateTimeOffset]$ResumedAtUtc,
    [Parameter(Mandatory)][ValidateRange(100, 100)][int]$ObservedTrafficPercent,
    [Parameter(Mandatory)][ValidateRange(5, 10080)][int]$ReviewIntervalMinutes,

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

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PostIncidentGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AssuranceScheduleReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TrafficStateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MonitoringEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DriftEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RollbackRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReviewedBy,

    [ValidateRange(1, 2160)][int]$MaxPostIncidentEvidenceAgeHours = 168,
    [ValidateRange(5, 1440)][int]$MaxResumptionAgeMinutes = 60,
    [string]$OutputDirectory = '.shieldward/production-assurance-resumption',
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
    [pscustomobject]@{ Value = $PostIncidentGateReference; Description = 'PostIncidentGateReference' }
    [pscustomobject]@{ Value = $AssuranceScheduleReference; Description = 'AssuranceScheduleReference' }
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $DriftEvidenceReference; Description = 'DriftEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackRetentionReference; Description = 'RollbackRetentionReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPostIncidentPath = Resolve-LocalStatePath -Path $PostIncidentEvidencePath -Description 'PostIncidentEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedPostIncidentPath -PathType Leaf)) {
    throw "Post-incident assurance evidence is missing: $resolvedPostIncidentPath"
}
$postValidationArguments = @{
    EvidencePath = $resolvedPostIncidentPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ClosureEvidencePath)) {
    $postValidationArguments.ClosureEvidencePath = $ClosureEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ClosurePlanPath)) {
    $postValidationArguments.ClosurePlanPath = $ClosurePlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $postValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-evidence.ps1') @postValidationArguments 6>$null

$postIncident = Get-Content -Raw -LiteralPath $resolvedPostIncidentPath | ConvertFrom-Json
if (
    [string]$postIncident.outcome -ne 'passed' -or
    [string]$postIncident.incident.status -ne 'closed' -or
    [bool]$postIncident.retrospective.recorded -ne $true -or
    [int]$postIncident.traffic.observedPercent -ne 100 -or
    [int]$postIncident.traffic.mutationPercentagePoints -ne 0 -or
    [string]$postIncident.rollback.retentionStatus -ne 'retained' -or
    [string]$postIncident.decision.nextAction -ne 'resume-continuous-production-assurance'
) {
    throw 'Assurance resumption requires passed post-incident assurance and retrospective evidence.'
}

$resumedAt = $ResumedAtUtc.ToUniversalTime()
$postCollectedAt = ([DateTimeOffset]$postIncident.collectedAtUtc).ToUniversalTime()
$postEvidenceAge = $referenceNow - $postCollectedAt
$resumptionAge = $referenceNow - $resumedAt
if (
    $resumedAt -lt $postCollectedAt -or
    $postEvidenceAge.TotalHours -lt -1 -or
    $postEvidenceAge.TotalHours -gt $MaxPostIncidentEvidenceAgeHours -or
    $resumptionAge.TotalMinutes -lt -5 -or
    $resumptionAge.TotalMinutes -gt $MaxResumptionAgeMinutes -or
    $referenceNow -gt $resumedAt.AddMinutes($ReviewIntervalMinutes + 5)
) {
    throw 'Assurance resumption must follow passed post-incident evidence, use current observations, and leave a future review boundary.'
}

$trafficMatchesPostIncident = $ObservedTrafficPercent -eq [int]$postIncident.traffic.observedPercent
$materialDriftDetected = @(
    $ImageDriftStatus,
    $PolicyDriftStatus,
    $ConfigurationDriftStatus,
    $IdentityDriftStatus,
    $RoutingDriftStatus
) -contains 'detected'
$hasFailure = (
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
    -not $trafficMatchesPostIncident
)
$hasUnknown = @(
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
$monitoringActivated = $AssuranceScheduleStatus -eq 'active' -and $MonitoringCoverageStatus -eq 'complete'
$assuranceResumed = $outcome -eq 'passed'
$nextAction = if ($materialDriftDetected) {
    'reaccept-before-continuing'
}
elseif ($SecurityStatus -eq 'incident' -or $CertificateStatus -eq 'invalid') {
    'disable-and-investigate'
}
elseif ($CertificateStatus -eq 'expiring') {
    'rotate-certificates-and-refresh-evidence'
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
$nextReviewDueAt = $resumedAt.AddMinutes($ReviewIntervalMinutes)
$postHash = (Get-FileHash -LiteralPath $resolvedPostIncidentPath -Algorithm SHA256).Hash.ToLowerInvariant()
$postRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPostIncidentPath).Replace('\', '/')
$integrity = [ordered]@{
    postIncidentEvidenceSha256 = $postHash
    postIncidentEvidenceIntegrityDigest = [string]$postIncident.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$postIncident.incidentId
    closureChangeId = [string]$postIncident.closureChangeId
    releaseVersion = [string]$postIncident.candidate.version
    sourceTag = [string]$postIncident.candidate.sourceTag
    controlPlaneImage = [string]$postIncident.candidate.controlPlaneImage
    edgeImage = [string]$postIncident.candidate.edgeImage
    policyVersion = [string]$postIncident.candidate.policyVersion
    postIncidentCollectedAtUtc = $postCollectedAt.ToString('o')
    resumedAtUtc = $resumedAt.ToString('o')
    collectedAtUtc = $collectedAt.ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
    reviewIntervalMinutes = $ReviewIntervalMinutes
    maxPostIncidentEvidenceAgeHours = $MaxPostIncidentEvidenceAgeHours
    maxResumptionAgeMinutes = $MaxResumptionAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPostIncident = $trafficMatchesPostIncident
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
    rollbackTargetPercent = [int]$postIncident.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$postIncident.rollback.emergencyTargetPercent
    postIncidentGateReference = $PostIncidentGateReference
    assuranceScheduleReference = $AssuranceScheduleReference
    trafficStateReference = $TrafficStateReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    driftEvidenceReference = $DriftEvidenceReference
    rollbackRetentionReference = $RollbackRetentionReference
    reviewedBy = $ReviewedBy
    monitoringActivated = $monitoringActivated
    assuranceResumed = $assuranceResumed
    outcome = $outcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'continuous-production-assurance-resumption'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$postIncident.incidentId
    closureChangeId = [string]$postIncident.closureChangeId
    postIncidentEvidence = [ordered]@{
        relativePath = $postRelativePath
        sha256 = $postHash
        integrityDigest = [string]$postIncident.integrityDigest
        collectedAtUtc = $postCollectedAt.ToString('o')
        outcome = [string]$postIncident.outcome
        retrospectiveRecorded = [bool]$postIncident.retrospective.recorded
    }
    candidate = [ordered]@{
        version = [string]$postIncident.candidate.version
        sourceTag = [string]$postIncident.candidate.sourceTag
        controlPlaneImage = [string]$postIncident.candidate.controlPlaneImage
        edgeImage = [string]$postIncident.candidate.edgeImage
        policyVersion = [string]$postIncident.candidate.policyVersion
    }
    schedule = [ordered]@{
        status = $AssuranceScheduleStatus
        monitoringCoverage = $MonitoringCoverageStatus
        resumedAtUtc = $resumedAt.ToString('o')
        reviewIntervalMinutes = $ReviewIntervalMinutes
        nextReviewDueAtUtc = $nextReviewDueAt.ToString('o')
        maxPostIncidentEvidenceAgeHours = $MaxPostIncidentEvidenceAgeHours
        maxResumptionAgeMinutes = $MaxResumptionAgeMinutes
    }
    traffic = [ordered]@{
        expectedPercent = 100
        observedPercent = $ObservedTrafficPercent
        matchesPostIncident = $trafficMatchesPostIncident
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
        targetPercent = [int]$postIncident.rollback.targetPercent
        emergencyTargetPercent = [int]$postIncident.rollback.emergencyTargetPercent
        authority = [string]$postIncident.rollback.authority
        procedureReference = [string]$postIncident.rollback.procedureReference
        retentionStatus = $RollbackRetentionStatus
    }
    externalEvidence = [ordered]@{
        postIncidentGateReference = $PostIncidentGateReference
        assuranceScheduleReference = $AssuranceScheduleReference
        trafficStateReference = $TrafficStateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        driftEvidenceReference = $DriftEvidenceReference
        rollbackRetentionReference = $RollbackRetentionReference
        reviewedBy = $ReviewedBy
    }
    decision = [ordered]@{
        monitoringActivated = $monitoringActivated
        assuranceResumed = $assuranceResumed
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'resumption-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance resumption evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Continuous production assurance resumption evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Assurance resumed: $assuranceResumed; next action: $nextAction"
Write-Host 'No scheduler, cluster, traffic, incident, or rollback changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Continuous assurance resumption is blocked. Preserve rollback and follow the recorded action.'
}
