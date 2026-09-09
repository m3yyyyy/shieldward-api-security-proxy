[CmdletBinding()]
param(
    [string]$EvidencePath = '.shieldward/production-canary/evidence.json',
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
    throw "Production canary evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'initial-canary-observation'
) {
    throw 'The supplied production canary evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The canary evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The canary evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedTrafficPlanPath = if ([string]::IsNullOrWhiteSpace($TrafficPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.trafficPlan.relativePath) -Description 'Recorded traffic plan path'
}
else {
    Resolve-LocalStatePath -Path $TrafficPlanPath -Description 'TrafficPlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedTrafficPlanPath -PathType Leaf)) {
    throw "Recorded production traffic plan is missing: $resolvedTrafficPlanPath"
}
$trafficPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedTrafficPlanPath).Replace('\', '/')
$trafficPlanHash = (Get-FileHash -LiteralPath $resolvedTrafficPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $trafficPlanRelativePath -ne [string]$evidence.trafficPlan.relativePath -or
    $trafficPlanHash -ne [string]$evidence.trafficPlan.sha256
) {
    throw 'The production traffic plan no longer matches the canary evidence.'
}

$trafficValidationArguments = @{
    PlanPath = $resolvedTrafficPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    ValidationPurpose = 'PostActivationEvidence'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $trafficValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') @trafficValidationArguments | Out-Null
$trafficPlan = Get-Content -Raw -LiteralPath $resolvedTrafficPlanPath | ConvertFrom-Json

$resolvedBaselinePath = if ([string]::IsNullOrWhiteSpace($BaselineEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$trafficPlan.baselineEvidence.relativePath) -Description 'Recorded baseline evidence path'
}
else {
    Resolve-LocalStatePath -Path $BaselineEvidencePath -Description 'BaselineEvidencePath'
}
$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    [string]$evidence.baselineEvidence.relativePath -ne [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/') -or
    [string]$evidence.baselineEvidence.sha256 -ne $baselineHash -or
    [string]$evidence.baselineEvidence.integrityDigest -ne [string]$trafficPlan.baselineEvidence.integrityDigest
) {
    throw 'The production baseline no longer matches the canary evidence.'
}

if (
    [string]$evidence.trafficPlan.integrityDigest -ne [string]$trafficPlan.integrityDigest -or
    [string]$evidence.trafficPlan.approvalDigest -ne [string]$trafficPlan.approval.approvalDigest -or
    [string]$evidence.trafficPlan.changeId -ne [string]$trafficPlan.changeId -or
    [string]$evidence.candidate.version -ne [string]$trafficPlan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$trafficPlan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$trafficPlan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$trafficPlan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$trafficPlan.candidate.policyVersion -or
    [string]$evidence.traffic.controller -ne [string]$trafficPlan.traffic.controller -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'The canary evidence no longer matches the approved candidate.'
}
if (
    [string]$evidence.rollback.mode -ne [string]$trafficPlan.rollback.mode -or
    [string]$evidence.rollback.targetState -ne [string]$trafficPlan.rollback.targetState -or
    [string]$evidence.rollback.authority -ne [string]$trafficPlan.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$trafficPlan.rollback.procedureReference
) {
    throw 'The canary evidence no longer matches the approved rollback path.'
}

try {
    $approvedAt = [DateTimeOffset]$trafficPlan.approval.approvedAtUtc
    $startedAt = [DateTimeOffset]$evidence.observation.startedAtUtc
    $endedAt = [DateTimeOffset]$evidence.observation.endedAtUtc
    $collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
}
catch {
    throw 'The canary evidence contains an invalid timestamp.'
}
$observedDuration = $endedAt.ToUniversalTime() - $startedAt.ToUniversalTime()
if (
    $startedAt -lt $approvedAt -or
    $endedAt -lt $startedAt -or
    $collectedAt -lt $endedAt -or
    $collectedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
    $observedDuration.TotalMinutes -lt [int]$trafficPlan.observationMinutes
) {
    throw 'The canary observation window is invalid or shorter than the approved duration.'
}
if (
    [int]$evidence.observation.requiredMinutes -ne [int]$trafficPlan.observationMinutes -or
    [int]$evidence.observation.observedMinutes -ne [int][Math]::Floor($observedDuration.TotalMinutes) -or
    [int]$evidence.observation.observedCanaryPercent -ne [int]$trafficPlan.traffic.canaryPercent -or
    [int]$evidence.observation.observedCanaryPercent -lt 1 -or
    [int]$evidence.observation.observedCanaryPercent -gt 10
) {
    throw 'The observed canary does not match the approved traffic plan.'
}

Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.trafficChangeReference) -Description 'Traffic change reference'
Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.monitoringEvidenceReference) -Description 'Monitoring evidence reference'
Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.reviewedBy) -Description 'Canary reviewer'

$signalContracts = @(
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$evidence.signals.errorBudget; Allowed = @('within-budget', 'exhausted', 'unknown'); Passing = 'within-budget' }
    [pscustomobject]@{ Name = 'alerts'; Actual = [string]$evidence.signals.alerts; Allowed = @('clear', 'firing', 'unknown'); Passing = 'clear' }
    [pscustomobject]@{ Name = 'functional checks'; Actual = [string]$evidence.signals.functional; Allowed = @('passed', 'failed', 'unknown'); Passing = 'passed' }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$evidence.signals.dependencies; Allowed = @('healthy', 'degraded', 'unknown'); Passing = 'healthy' }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$evidence.signals.operations; Allowed = @('healthy', 'degraded', 'unknown'); Passing = 'healthy' }
)
$hasFailure = $false
$hasUnknown = $false
foreach ($signal in $signalContracts) {
    if ($signal.Allowed -notcontains $signal.Actual) {
        throw "The canary evidence contains unsupported $($signal.Name) status '$($signal.Actual)'."
    }
    if ($signal.Actual -eq 'unknown') {
        $hasUnknown = $true
    }
    elseif ($signal.Actual -ne $signal.Passing) {
        $hasFailure = $true
    }
}
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
if ([string]$evidence.outcome -ne $expectedOutcome) {
    throw "The canary evidence outcome must be '$expectedOutcome' for the recorded signals."
}
if (
    [string]$evidence.checks.liveClusterVerification -ne 'passed' -or
    [bool]$evidence.checks.trafficControllerExternallyEnforced -ne $true
) {
    throw 'The canary evidence lacks the required live verification and external traffic-control assertions.'
}

$integrity = [ordered]@{
    trafficPlanSha256 = [string]$evidence.trafficPlan.sha256
    trafficPlanIntegrityDigest = [string]$evidence.trafficPlan.integrityDigest
    trafficPlanApprovalDigest = [string]$evidence.trafficPlan.approvalDigest
    baselineEvidenceSha256 = [string]$evidence.baselineEvidence.sha256
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    productionContext = [string]$evidence.productionContext
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    observedCanaryPercent = [int]$evidence.observation.observedCanaryPercent
    observationStartedAtUtc = $startedAt.ToUniversalTime().ToString('o')
    observationEndedAtUtc = $endedAt.ToUniversalTime().ToString('o')
    requiredObservationMinutes = [int]$evidence.observation.requiredMinutes
    errorBudgetStatus = [string]$evidence.signals.errorBudget
    alertStatus = [string]$evidence.signals.alerts
    functionalStatus = [string]$evidence.signals.functional
    dependencyStatus = [string]$evidence.signals.dependencies
    operationalStatus = [string]$evidence.signals.operations
    trafficChangeReference = [string]$evidence.externalEvidence.trafficChangeReference
    monitoringEvidenceReference = [string]$evidence.externalEvidence.monitoringEvidenceReference
    reviewedBy = [string]$evidence.externalEvidence.reviewedBy
    outcome = [string]$evidence.outcome
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production canary evidence integrity digest is invalid.'
}

Write-Host "Production canary evidence validation passed with outcome '$($evidence.outcome)'."
Write-Host 'This validator is read-only and does not change or authorize traffic routing.'
