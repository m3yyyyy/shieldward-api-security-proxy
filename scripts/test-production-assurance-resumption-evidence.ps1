[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
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
    throw "Production assurance resumption evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'continuous-production-assurance-resumption'
) {
    throw 'The supplied production assurance resumption evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The assurance resumption evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The assurance resumption evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPostIncidentPath = if ([string]::IsNullOrWhiteSpace($PostIncidentEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.postIncidentEvidence.relativePath) -Description 'Recorded post-incident evidence path'
}
else {
    Resolve-LocalStatePath -Path $PostIncidentEvidencePath -Description 'PostIncidentEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedPostIncidentPath -PathType Leaf)) {
    throw "Recorded post-incident assurance evidence is missing: $resolvedPostIncidentPath"
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
$postRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPostIncidentPath).Replace('\', '/')
$postHash = (Get-FileHash -LiteralPath $resolvedPostIncidentPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $postRelativePath -ne [string]$evidence.postIncidentEvidence.relativePath -or
    $postHash -ne [string]$evidence.postIncidentEvidence.sha256 -or
    [string]$postIncident.integrityDigest -ne [string]$evidence.postIncidentEvidence.integrityDigest -or
    ([DateTimeOffset]$postIncident.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.postIncidentEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.postIncidentEvidence.outcome -ne 'passed' -or
    [bool]$evidence.postIncidentEvidence.retrospectiveRecorded -ne $true
) {
    throw 'The passed post-incident assurance evidence no longer matches assurance resumption evidence.'
}
if (
    [string]$postIncident.outcome -ne 'passed' -or
    [string]$postIncident.incident.status -ne 'closed' -or
    [bool]$postIncident.retrospective.recorded -ne $true -or
    [string]$postIncident.rollback.retentionStatus -ne 'retained' -or
    [string]$postIncident.decision.nextAction -ne 'resume-continuous-production-assurance'
) {
    throw 'Assurance resumption evidence requires passed post-incident assurance and retrospective evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$postIncident.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$postIncident.closureChangeId
) {
    throw 'The assurance resumption identity does not match post-incident evidence.'
}
if (
    [string]$evidence.candidate.version -ne [string]$postIncident.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$postIncident.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$postIncident.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$postIncident.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$postIncident.candidate.policyVersion
) {
    throw 'The assurance resumption candidate does not match post-incident evidence.'
}

$statusContracts = @(
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
        throw "The assurance resumption evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.postIncidentGateReference; Description = 'Post-incident gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.assuranceScheduleReference; Description = 'Assurance schedule reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.driftEvidenceReference; Description = 'Drift evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackRetentionReference; Description = 'Rollback retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$trafficMatchesPostIncident = [int]$evidence.traffic.observedPercent -eq [int]$postIncident.traffic.observedPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [int]$postIncident.traffic.observedPercent -ne 100 -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesPostIncident -ne $trafficMatchesPostIncident -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0
) {
    throw 'The assurance resumption traffic evidence is inconsistent with the post-incident 100-percent boundary.'
}
if (
    [int]$evidence.rollback.targetPercent -ne [int]$postIncident.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$postIncident.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$postIncident.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$postIncident.rollback.procedureReference
) {
    throw 'The assurance resumption rollback evidence is inconsistent with post-incident evidence.'
}

$postCollectedAt = ([DateTimeOffset]$postIncident.collectedAtUtc).ToUniversalTime()
$resumedAt = ([DateTimeOffset]$evidence.schedule.resumedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$reviewIntervalMinutes = [int]$evidence.schedule.reviewIntervalMinutes
$postAgeAtCollection = $collectedAt - $postCollectedAt
$resumptionAgeAtCollection = $collectedAt - $resumedAt
if (
    $resumedAt -lt $postCollectedAt -or
    $reviewIntervalMinutes -lt 5 -or
    $reviewIntervalMinutes -gt 10080 -or
    $nextReviewDueAt.ToString('o') -ne $resumedAt.AddMinutes($reviewIntervalMinutes).ToString('o') -or
    [int]$evidence.schedule.maxPostIncidentEvidenceAgeHours -lt 1 -or
    [int]$evidence.schedule.maxPostIncidentEvidenceAgeHours -gt 2160 -or
    $postAgeAtCollection.TotalHours -lt -1 -or
    $postAgeAtCollection.TotalHours -gt [int]$evidence.schedule.maxPostIncidentEvidenceAgeHours -or
    [int]$evidence.schedule.maxResumptionAgeMinutes -lt 5 -or
    [int]$evidence.schedule.maxResumptionAgeMinutes -gt 1440 -or
    $resumptionAgeAtCollection.TotalMinutes -lt -5 -or
    $resumptionAgeAtCollection.TotalMinutes -gt [int]$evidence.schedule.maxResumptionAgeMinutes -or
    $collectedAt -gt $nextReviewDueAt.AddMinutes(5) -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The assurance resumption schedule, evidence age, or freshness boundary is invalid.'
}

$materialDriftDetected = @(
    [string]$evidence.drift.images,
    [string]$evidence.drift.policy,
    [string]$evidence.drift.configuration,
    [string]$evidence.drift.identity,
    [string]$evidence.drift.routing
) -contains 'detected'
$hasFailure = (
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
    -not $trafficMatchesPostIncident
)
$hasUnknown = @(
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
$expectedMonitoringActivated = (
    [string]$evidence.schedule.status -eq 'active' -and
    [string]$evidence.schedule.monitoringCoverage -eq 'complete'
)
$expectedAssuranceResumed = $expectedOutcome -eq 'passed'
$expectedNextAction = if ($materialDriftDetected) {
    'reaccept-before-continuing'
}
elseif ([string]$evidence.signals.security -eq 'incident' -or [string]$evidence.drift.certificates -eq 'invalid') {
    'disable-and-investigate'
}
elseif ([string]$evidence.drift.certificates -eq 'expiring') {
    'rotate-certificates-and-refresh-evidence'
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
    [bool]$evidence.decision.monitoringActivated -ne $expectedMonitoringActivated -or
    [bool]$evidence.decision.assuranceResumed -ne $expectedAssuranceResumed -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The assurance resumption outcome or required action is inconsistent with recorded evidence.'
}

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
    reviewIntervalMinutes = $reviewIntervalMinutes
    maxPostIncidentEvidenceAgeHours = [int]$evidence.schedule.maxPostIncidentEvidenceAgeHours
    maxResumptionAgeMinutes = [int]$evidence.schedule.maxResumptionAgeMinutes
    expectedTrafficPercent = 100
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesPostIncident = $trafficMatchesPostIncident
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
    rollbackTargetPercent = [int]$postIncident.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$postIncident.rollback.emergencyTargetPercent
    postIncidentGateReference = [string]$evidence.externalEvidence.postIncidentGateReference
    assuranceScheduleReference = [string]$evidence.externalEvidence.assuranceScheduleReference
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    monitoringEvidenceReference = [string]$evidence.externalEvidence.monitoringEvidenceReference
    driftEvidenceReference = [string]$evidence.externalEvidence.driftEvidenceReference
    rollbackRetentionReference = [string]$evidence.externalEvidence.rollbackRetentionReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    monitoringActivated = $expectedMonitoringActivated
    assuranceResumed = $expectedAssuranceResumed
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance resumption evidence integrity digest is invalid.'
}

Write-Host "Continuous production assurance resumption evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Assurance resumed: $expectedAssuranceResumed; next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not activate schedulers, change production, or remove rollback.'
