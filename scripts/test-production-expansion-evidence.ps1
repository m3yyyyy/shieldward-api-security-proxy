[CmdletBinding()]
param(
    [string]$EvidencePath = '.shieldward/production-expansion-evidence/evidence.json',
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
    throw "Production first-expansion evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'first-expansion-observation'
) {
    throw 'The supplied production first-expansion evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The first-expansion evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The first-expansion evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedExpansionPlanPath = if ([string]::IsNullOrWhiteSpace($ExpansionPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.expansionPlan.relativePath) -Description 'Recorded expansion plan path'
}
else {
    Resolve-LocalStatePath -Path $ExpansionPlanPath -Description 'ExpansionPlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedExpansionPlanPath -PathType Leaf)) {
    throw "Recorded production expansion plan is missing: $resolvedExpansionPlanPath"
}
$expansionPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedExpansionPlanPath).Replace('\', '/')
$expansionPlanHash = (Get-FileHash -LiteralPath $resolvedExpansionPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $expansionPlanRelativePath -ne [string]$evidence.expansionPlan.relativePath -or
    $expansionPlanHash -ne [string]$evidence.expansionPlan.sha256
) {
    throw 'The production expansion plan no longer matches the observation evidence.'
}

$planValidationArguments = @{
    PlanPath = $resolvedExpansionPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    ValidationPurpose = 'PostExpansionEvidence'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'CanaryEvidencePath'; Value = $CanaryEvidencePath }
    [pscustomobject]@{ Name = 'TrafficPlanPath'; Value = $TrafficPlanPath }
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $planValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') @planValidationArguments | Out-Null
$expansionPlan = Get-Content -Raw -LiteralPath $resolvedExpansionPlanPath | ConvertFrom-Json

if (
    [string]$evidence.expansionPlan.integrityDigest -ne [string]$expansionPlan.integrityDigest -or
    [string]$evidence.expansionPlan.approvalDigest -ne [string]$expansionPlan.approval.approvalDigest -or
    [string]$evidence.expansionPlan.changeId -ne [string]$expansionPlan.changeId -or
    [string]$evidence.candidate.version -ne [string]$expansionPlan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$expansionPlan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$expansionPlan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$expansionPlan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$expansionPlan.candidate.policyVersion -or
    [string]$evidence.traffic.controller -ne [string]$expansionPlan.traffic.controller -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'The first-expansion evidence no longer matches the approved candidate and traffic plan.'
}
if (
    [string]$evidence.rollback.mode -ne [string]$expansionPlan.rollback.mode -or
    [string]$evidence.rollback.targetState -ne [string]$expansionPlan.rollback.targetState -or
    [string]$evidence.rollback.authority -ne [string]$expansionPlan.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$expansionPlan.rollback.procedureReference
) {
    throw 'The first-expansion evidence no longer matches the approved emergency rollback path.'
}

try {
    $approvedAt = [DateTimeOffset]$expansionPlan.approval.approvedAtUtc
    $startedAt = [DateTimeOffset]$evidence.observation.startedAtUtc
    $endedAt = [DateTimeOffset]$evidence.observation.endedAtUtc
    $collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
}
catch {
    throw 'The first-expansion evidence contains an invalid timestamp.'
}
$observedDuration = $endedAt.ToUniversalTime() - $startedAt.ToUniversalTime()
if (
    $startedAt -lt $approvedAt -or
    $endedAt -lt $startedAt -or
    $collectedAt -lt $endedAt -or
    $collectedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
    $observedDuration.TotalMinutes -lt [int]$expansionPlan.observationMinutes
) {
    throw 'The first-expansion observation window is invalid or shorter than the approved duration.'
}
if (
    [int]$evidence.observation.previousTrafficPercent -ne [int]$expansionPlan.traffic.currentPercent -or
    [int]$evidence.observation.observedTrafficPercent -ne [int]$expansionPlan.traffic.targetPercent -or
    [int]$evidence.observation.requiredMinutes -ne [int]$expansionPlan.observationMinutes -or
    [int]$evidence.observation.observedMinutes -ne [int][Math]::Floor($observedDuration.TotalMinutes) -or
    [int]$evidence.observation.observedTrafficPercent -gt 25
) {
    throw 'The observed first expansion does not match the approved target.'
}

Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.trafficChangeReference) -Description 'Traffic change reference'
Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.monitoringEvidenceReference) -Description 'Monitoring evidence reference'
Assert-EvidenceReference -Value ([string]$evidence.externalEvidence.reviewedBy) -Description 'Expansion reviewer'

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
        throw "The evidence contains unsupported $($signal.Name) status '$($signal.Actual)'."
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
    throw "The first-expansion evidence outcome must be '$expectedOutcome' for the recorded signals."
}
if (
    [string]$evidence.checks.liveClusterVerification -ne 'passed' -or
    [bool]$evidence.checks.trafficControllerExternallyEnforced -ne $true
) {
    throw 'The evidence lacks the required live verification and external traffic-control assertions.'
}

$integrity = [ordered]@{
    expansionPlanSha256 = [string]$evidence.expansionPlan.sha256
    expansionPlanIntegrityDigest = [string]$evidence.expansionPlan.integrityDigest
    expansionPlanApprovalDigest = [string]$evidence.expansionPlan.approvalDigest
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    productionContext = [string]$evidence.productionContext
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    previousTrafficPercent = [int]$evidence.observation.previousTrafficPercent
    observedTrafficPercent = [int]$evidence.observation.observedTrafficPercent
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
    throw 'The production first-expansion evidence integrity digest is invalid.'
}

Write-Host "Production first-expansion evidence validation passed with outcome '$($evidence.outcome)'."
Write-Host 'This validator is read-only and does not change or authorize traffic routing.'
