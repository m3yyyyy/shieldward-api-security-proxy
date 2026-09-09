[CmdletBinding()]
param(
    [string]$ExpansionPlanPath = '.shieldward/production-expansion/expansion.json',
    [string]$CanaryEvidencePath = '',
    [string]$TrafficPlanPath = '',
    [string]$BaselineEvidencePath = '',
    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidateRange(2, 25)]
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

    [string]$OutputDirectory = '.shieldward/production-expansion-evidence',
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

$resolvedExpansionPlanPath = Resolve-LocalStatePath -Path $ExpansionPlanPath -Description 'ExpansionPlanPath'
if (-not (Test-Path -LiteralPath $resolvedExpansionPlanPath -PathType Leaf)) {
    throw "Approved production expansion plan is missing: $resolvedExpansionPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedExpansionPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    ValidationPurpose = 'PostExpansionEvidence'
    CheckCluster = $true
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
if ($ObservedTrafficPercent -ne [int]$expansionPlan.traffic.targetPercent) {
    throw "ObservedTrafficPercent must exactly match the approved $($expansionPlan.traffic.targetPercent)% target."
}

try {
    $approvedAt = [DateTimeOffset]$expansionPlan.approval.approvedAtUtc
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
    $endedAt -gt $collectedAt.AddMinutes(5) -or
    $observedDuration.TotalMinutes -lt [int]$expansionPlan.observationMinutes
) {
    throw 'The observation must begin after approval, end no later than collection, and cover the full approved window.'
}

$expansionPlanHash = (Get-FileHash -LiteralPath $resolvedExpansionPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expansionPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedExpansionPlanPath).Replace('\', '/')
$hasFailure = (
    $ErrorBudgetStatus -eq 'exhausted' -or
    $AlertStatus -eq 'firing' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded'
)
$hasUnknown = @(
    $ErrorBudgetStatus,
    $AlertStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }

$integrity = [ordered]@{
    expansionPlanSha256 = $expansionPlanHash
    expansionPlanIntegrityDigest = [string]$expansionPlan.integrityDigest
    expansionPlanApprovalDigest = [string]$expansionPlan.approval.approvalDigest
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    productionContext = $ExpectedProductionContext
    releaseVersion = [string]$expansionPlan.candidate.version
    sourceTag = [string]$expansionPlan.candidate.sourceTag
    controlPlaneImage = [string]$expansionPlan.candidate.controlPlaneImage
    edgeImage = [string]$expansionPlan.candidate.edgeImage
    policyVersion = [string]$expansionPlan.candidate.policyVersion
    trafficController = [string]$expansionPlan.traffic.controller
    previousTrafficPercent = [int]$expansionPlan.traffic.currentPercent
    observedTrafficPercent = $ObservedTrafficPercent
    observationStartedAtUtc = $startedAt.ToUniversalTime().ToString('o')
    observationEndedAtUtc = $endedAt.ToUniversalTime().ToString('o')
    requiredObservationMinutes = [int]$expansionPlan.observationMinutes
    errorBudgetStatus = $ErrorBudgetStatus
    alertStatus = $AlertStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    trafficChangeReference = $TrafficChangeReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    reviewedBy = $ReviewedBy
    outcome = $outcome
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'first-expansion-observation'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    expansionPlan = [ordered]@{
        relativePath = $expansionPlanRelativePath
        sha256 = $expansionPlanHash
        integrityDigest = [string]$expansionPlan.integrityDigest
        approvalDigest = [string]$expansionPlan.approval.approvalDigest
        changeId = [string]$expansionPlan.changeId
    }
    candidate = [ordered]@{
        version = [string]$expansionPlan.candidate.version
        sourceTag = [string]$expansionPlan.candidate.sourceTag
        controlPlaneImage = [string]$expansionPlan.candidate.controlPlaneImage
        edgeImage = [string]$expansionPlan.candidate.edgeImage
        policyVersion = [string]$expansionPlan.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$expansionPlan.traffic.controller
        externallyEnforced = $true
    }
    observation = [ordered]@{
        previousTrafficPercent = [int]$expansionPlan.traffic.currentPercent
        observedTrafficPercent = $ObservedTrafficPercent
        startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        endedAtUtc = $endedAt.ToUniversalTime().ToString('o')
        requiredMinutes = [int]$expansionPlan.observationMinutes
        observedMinutes = [int][Math]::Floor($observedDuration.TotalMinutes)
    }
    signals = [ordered]@{
        errorBudget = $ErrorBudgetStatus
        alerts = $AlertStatus
        functional = $FunctionalStatus
        dependencies = $DependencyStatus
        operations = $OperationalStatus
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
        mode = [string]$expansionPlan.rollback.mode
        targetState = [string]$expansionPlan.rollback.targetState
        authority = [string]$expansionPlan.rollback.authority
        procedureReference = [string]$expansionPlan.rollback.procedureReference
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$evidencePath = Join-Path $resolvedOutputDirectory 'evidence.json'
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production first-expansion evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production first-expansion evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Further expansion is blocked. Restore the previous cohort or disable traffic through the authoritative controller.'
}
