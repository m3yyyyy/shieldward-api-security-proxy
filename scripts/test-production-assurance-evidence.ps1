[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$AcceptedFullTrafficEvidencePath = '',
    [string]$FinalExpansionPlanPath = '',
    [string]$SecondExpansionEvidencePath = '',
    [string]$SecondExpansionPlanPath = '',
    [string]$ProgressiveEvidencePath = '',
    [string]$ProgressivePlanPath = '',
    [string]$ExpansionEvidencePath = '',
    [string]$ExpansionPlanPath = '',
    [string]$CanaryEvidencePath = '',
    [string]$TrafficPlanPath = '',
    [string]$BaselineEvidencePath = '',
    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [switch]$CheckCluster
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
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

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
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Description
    )

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

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production assurance evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'ongoing-production-assurance'
) {
    throw 'The supplied production assurance evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The assurance evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The assurance evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedAcceptedEvidencePath = if ([string]::IsNullOrWhiteSpace($AcceptedFullTrafficEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.acceptedFullTrafficEvidence.relativePath) -Description 'Recorded accepted full-traffic evidence path'
}
else {
    Resolve-LocalStatePath -Path $AcceptedFullTrafficEvidencePath -Description 'AcceptedFullTrafficEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedAcceptedEvidencePath -PathType Leaf)) {
    throw "Recorded accepted full-traffic evidence is missing: $resolvedAcceptedEvidencePath"
}
$acceptedRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedAcceptedEvidencePath).Replace('\', '/')
$acceptedHash = (Get-FileHash -LiteralPath $resolvedAcceptedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $acceptedRelativePath -ne [string]$evidence.acceptedFullTrafficEvidence.relativePath -or
    $acceptedHash -ne [string]$evidence.acceptedFullTrafficEvidence.sha256
) {
    throw 'The accepted full-traffic evidence no longer matches the assurance evidence.'
}

$acceptanceArguments = @{
    EvidencePath = $resolvedAcceptedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    ValidationPurpose = 'OngoingAssurance'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'FinalExpansionPlanPath'; Value = $FinalExpansionPlanPath }
    [pscustomobject]@{ Name = 'SecondExpansionEvidencePath'; Value = $SecondExpansionEvidencePath }
    [pscustomobject]@{ Name = 'SecondExpansionPlanPath'; Value = $SecondExpansionPlanPath }
    [pscustomobject]@{ Name = 'ProgressiveEvidencePath'; Value = $ProgressiveEvidencePath }
    [pscustomobject]@{ Name = 'ProgressivePlanPath'; Value = $ProgressivePlanPath }
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'CanaryEvidencePath'; Value = $CanaryEvidencePath }
    [pscustomobject]@{ Name = 'TrafficPlanPath'; Value = $TrafficPlanPath }
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $acceptanceArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @acceptanceArguments | Out-Null
$acceptedEvidence = Get-Content -Raw -LiteralPath $resolvedAcceptedEvidencePath | ConvertFrom-Json

if (
    [string]$evidence.acceptedFullTrafficEvidence.integrityDigest -ne [string]$acceptedEvidence.integrityDigest -or
    [string]$evidence.acceptedFullTrafficEvidence.outcome -ne 'passed' -or
    ([DateTimeOffset]$evidence.acceptedFullTrafficEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -ne ([DateTimeOffset]$acceptedEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$evidence.candidate.version -ne [string]$acceptedEvidence.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$acceptedEvidence.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$acceptedEvidence.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$acceptedEvidence.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$acceptedEvidence.candidate.policyVersion -or
    [string]$evidence.traffic.controller -ne [string]$acceptedEvidence.traffic.controller -or
    [int]$evidence.traffic.observedTrafficPercent -ne 100 -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'The assurance evidence no longer matches the accepted full-traffic candidate and state.'
}
if (
    [string]$evidence.rollback.mode -ne [string]$acceptedEvidence.rollback.mode -or
    [int]$evidence.rollback.targetPercent -ne [int]$acceptedEvidence.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$acceptedEvidence.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$acceptedEvidence.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$acceptedEvidence.rollback.procedureReference
) {
    throw 'The assurance evidence no longer matches the accepted rollback path.'
}

try {
    $collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
    $nextReviewDueAt = [DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc
}
catch {
    throw 'The assurance evidence contains an invalid timestamp.'
}
$reviewIntervalMinutes = [int]$evidence.schedule.reviewIntervalMinutes
if (
    $reviewIntervalMinutes -lt 5 -or
    $reviewIntervalMinutes -gt 10080 -or
    $collectedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
    $nextReviewDueAt.ToUniversalTime().ToString('o') -ne $collectedAt.AddMinutes($reviewIntervalMinutes).ToUniversalTime().ToString('o')
) {
    throw 'The assurance review interval or next-review boundary is invalid.'
}

foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.driftEvidenceReference; Description = 'Drift evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.reviewedBy; Description = 'Assurance reviewer' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$signalContracts = @(
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$evidence.signals.errorBudget; Allowed = @('within-budget', 'exhausted', 'unknown'); Passing = 'within-budget' }
    [pscustomobject]@{ Name = 'alerts'; Actual = [string]$evidence.signals.alerts; Allowed = @('clear', 'firing', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'functional checks'; Actual = [string]$evidence.signals.functional; Allowed = @('passed', 'failed', 'unknown'); Passing = 'passed' }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$evidence.signals.dependencies; Allowed = @('healthy', 'degraded', 'unknown'); Passing = 'healthy' }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$evidence.signals.operations; Allowed = @('healthy', 'degraded', 'unknown'); Passing = 'healthy' }
    [pscustomobject]@{ Name = 'capacity'; Actual = [string]$evidence.signals.capacity; Allowed = @('healthy', 'degraded', 'unknown'); Passing = 'healthy' }
    [pscustomobject]@{ Name = 'security'; Actual = [string]$evidence.signals.security; Allowed = @('clear', 'incident', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'image drift'; Actual = [string]$evidence.drift.images; Allowed = @('clear', 'detected', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'policy drift'; Actual = [string]$evidence.drift.policy; Allowed = @('clear', 'detected', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'configuration drift'; Actual = [string]$evidence.drift.configuration; Allowed = @('clear', 'detected', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'identity drift'; Actual = [string]$evidence.drift.identity; Allowed = @('clear', 'detected', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'certificates'; Actual = [string]$evidence.drift.certificates; Allowed = @('healthy', 'expiring', 'invalid', 'unknown'); Passing = 'healthy' }
    [pscustomobject]@{ Name = 'routing drift'; Actual = [string]$evidence.drift.routing; Allowed = @('clear', 'detected', 'unknown'); Passing = 'clear' }
)
$hasFailure = $false
$hasUnknown = $false
foreach ($signal in $signalContracts) {
    if ($signal.Allowed -notcontains $signal.Actual) {
        throw "The evidence contains unsupported $($signal.Name) status '$($signal.Actual)'."
    }
    if ($signal.Actual -eq 'unknown') {
        $hasUnknown = $true
    }
    elseif ($signal.Actual -ne $signal.Passing) {
        $hasFailure = $true
    }
}
$materialDriftDetected = @(
    [string]$evidence.drift.images,
    [string]$evidence.drift.policy,
    [string]$evidence.drift.configuration,
    [string]$evidence.drift.identity,
    [string]$evidence.drift.routing
) -contains 'detected'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedAction = if ($materialDriftDetected) {
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
    'continue-monitoring'
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.reacceptanceRequired -ne $materialDriftDetected -or
    [string]$evidence.decision.requiredAction -ne $expectedAction
) {
    throw 'The assurance outcome or required action is inconsistent with the recorded signals.'
}
if (
    [string]$evidence.checks.liveClusterVerification -ne 'passed' -or
    [bool]$evidence.checks.trafficControllerExternallyEnforced -ne $true
) {
    throw 'The assurance evidence lacks live verification or external full-traffic enforcement.'
}

$integrity = [ordered]@{
    acceptedFullTrafficEvidenceSha256 = [string]$evidence.acceptedFullTrafficEvidence.sha256
    acceptedFullTrafficEvidenceIntegrityDigest = [string]$evidence.acceptedFullTrafficEvidence.integrityDigest
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToUniversalTime().ToString('o')
    reviewIntervalMinutes = $reviewIntervalMinutes
    productionContext = [string]$evidence.productionContext
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    observedTrafficPercent = [int]$evidence.traffic.observedTrafficPercent
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
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    monitoringEvidenceReference = [string]$evidence.externalEvidence.monitoringEvidenceReference
    driftEvidenceReference = [string]$evidence.externalEvidence.driftEvidenceReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    reacceptanceRequired = [bool]$evidence.decision.reacceptanceRequired
    requiredAction = [string]$evidence.decision.requiredAction
    outcome = [string]$evidence.outcome
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production assurance evidence integrity digest is invalid.'
}

Write-Host "Production assurance evidence validation passed with outcome '$($evidence.outcome)'."
Write-Host 'This validator is read-only and does not change production or replace external monitoring.'
