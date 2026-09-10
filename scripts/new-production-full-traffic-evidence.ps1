[CmdletBinding()]
param(
    [string]$FinalExpansionPlanPath = '.shieldward/production-final-expansion/expansion.json',
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

    [Parameter(Mandatory)]
    [ValidateRange(100, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ObservationStartedAtUtc,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ObservationEndedAtUtc,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficChangeReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MonitoringEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewedBy,

    [Parameter(Mandatory)]
    [ValidateSet('within-budget', 'exhausted', 'unknown')]
    [string]$ErrorBudgetStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'firing', 'unknown')]
    [string]$AlertStatus,

    [Parameter(Mandatory)]
    [ValidateSet('passed', 'failed', 'unknown')]
    [string]$FunctionalStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$DependencyStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$OperationalStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$CapacityStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'incident', 'unknown')]
    [string]$SecurityStatus,

    [string]$OutputDirectory = '.shieldward/production-full-traffic-evidence',
    [switch]$Force
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

foreach ($reference in @(
    [pscustomobject]@{ Value = $TrafficChangeReference; Description = 'TrafficChangeReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $FinalExpansionPlanPath -Description 'FinalExpansionPlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Approved production final expansion plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    ValidationPurpose = 'PostExpansionEvidence'
    CheckCluster = $true
}
foreach ($optionalPath in @(
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
        $planValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @planValidationArguments | Out-Null
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if ($ObservedTrafficPercent -ne [int]$plan.traffic.targetPercent -or $ObservedTrafficPercent -ne 100) {
    throw 'ObservedTrafficPercent must exactly match the approved 100% target.'
}

try {
    $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    $startedAt = [DateTimeOffset]$ObservationStartedAtUtc
    $endedAt = [DateTimeOffset]$ObservationEndedAtUtc
}
catch {
    throw 'ObservationStartedAtUtc and ObservationEndedAtUtc must be valid timestamps with offsets.'
}
$collectedAt = [DateTimeOffset]::UtcNow
$observedDuration = $endedAt.ToUniversalTime() - $startedAt.ToUniversalTime()
if (
    $startedAt -lt $approvedAt -or
    $endedAt -lt $startedAt -or
    $endedAt -gt $collectedAt -or
    $observedDuration.TotalMinutes -lt [int]$plan.observationMinutes
) {
    throw 'The full-traffic observation must begin after approval, end no later than collection, and cover the full approved window.'
}

$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$hasFailure = (
    $ErrorBudgetStatus -eq 'exhausted' -or
    $AlertStatus -eq 'firing' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident'
)
$hasUnknown = @(
    $ErrorBudgetStatus,
    $AlertStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus,
    $CapacityStatus,
    $SecurityStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }

$integrity = [ordered]@{
    finalExpansionPlanSha256 = $planHash
    finalExpansionPlanIntegrityDigest = [string]$plan.integrityDigest
    finalExpansionPlanApprovalDigest = [string]$plan.approval.approvalDigest
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    productionContext = $ExpectedProductionContext
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    trafficController = [string]$plan.traffic.controller
    previousTrafficPercent = [int]$plan.traffic.currentPercent
    observedTrafficPercent = $ObservedTrafficPercent
    observationStartedAtUtc = $startedAt.ToUniversalTime().ToString('o')
    observationEndedAtUtc = $endedAt.ToUniversalTime().ToString('o')
    requiredObservationMinutes = [int]$plan.observationMinutes
    errorBudgetStatus = $ErrorBudgetStatus
    alertStatus = $AlertStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    capacityStatus = $CapacityStatus
    securityStatus = $SecurityStatus
    trafficChangeReference = $TrafficChangeReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    reviewedBy = $ReviewedBy
    outcome = $outcome
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'full-traffic-observation'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    finalExpansionPlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        changeId = [string]$plan.changeId
    }
    candidate = [ordered]@{
        version = [string]$plan.candidate.version
        sourceTag = [string]$plan.candidate.sourceTag
        controlPlaneImage = [string]$plan.candidate.controlPlaneImage
        edgeImage = [string]$plan.candidate.edgeImage
        policyVersion = [string]$plan.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$plan.traffic.controller
        externallyEnforced = $true
    }
    observation = [ordered]@{
        previousTrafficPercent = [int]$plan.traffic.currentPercent
        observedTrafficPercent = $ObservedTrafficPercent
        startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        endedAtUtc = $endedAt.ToUniversalTime().ToString('o')
        requiredMinutes = [int]$plan.observationMinutes
        observedMinutes = [int][Math]::Floor($observedDuration.TotalMinutes)
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
    externalEvidence = [ordered]@{
        trafficChangeReference = $TrafficChangeReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        reviewedBy = $ReviewedBy
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    rollback = [ordered]@{
        mode = [string]$plan.rollback.mode
        targetPercent = [int]$plan.rollback.targetPercent
        emergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
        authority = [string]$plan.rollback.authority
        procedureReference = [string]$plan.rollback.procedureReference
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$evidencePath = Join-Path $resolvedOutputDirectory 'evidence.json'
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production full-traffic evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production full-traffic evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Steady-state acceptance is blocked. Restore the 75 percent cohort or disable traffic through the authoritative controller.'
}
