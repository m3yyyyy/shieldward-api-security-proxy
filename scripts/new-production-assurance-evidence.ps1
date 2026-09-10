[CmdletBinding()]
param(
    [string]$AcceptedFullTrafficEvidencePath = '.shieldward/production-full-traffic-evidence/evidence.json',
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

    [Parameter(Mandatory)]
    [ValidateRange(100, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateRange(5, 10080)]
    [int]$ReviewIntervalMinutes,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MonitoringEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DriftEvidenceReference,

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

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$ImageDriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$PolicyDriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$ConfigurationDriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$IdentityDriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'expiring', 'invalid', 'unknown')]
    [string]$CertificateStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$RoutingDriftStatus,

    [string]$OutputDirectory = '.shieldward/production-assurance',
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
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $DriftEvidenceReference; Description = 'DriftEvidenceReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedAcceptedEvidencePath = Resolve-LocalStatePath -Path $AcceptedFullTrafficEvidencePath -Description 'AcceptedFullTrafficEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedAcceptedEvidencePath -PathType Leaf)) {
    throw "Accepted production full-traffic evidence is missing: $resolvedAcceptedEvidencePath"
}
$acceptanceArguments = @{
    EvidencePath = $resolvedAcceptedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    ValidationPurpose = 'OngoingAssurance'
    CheckCluster = $true
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
if ($ObservedTrafficPercent -ne [int]$acceptedEvidence.observation.observedTrafficPercent -or $ObservedTrafficPercent -ne 100) {
    throw 'ObservedTrafficPercent must remain exactly 100 percent for ongoing assurance.'
}

$collectedAt = [DateTimeOffset]::UtcNow
$nextReviewDueAt = $collectedAt.AddMinutes($ReviewIntervalMinutes)
$materialDriftDetected = @(
    $ImageDriftStatus,
    $PolicyDriftStatus,
    $ConfigurationDriftStatus,
    $IdentityDriftStatus,
    $RoutingDriftStatus
) -contains 'detected'
$hasFailure = (
    $ErrorBudgetStatus -eq 'exhausted' -or
    $AlertStatus -eq 'firing' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident' -or
    $materialDriftDetected -or
    $CertificateStatus -in @('expiring', 'invalid')
)
$hasUnknown = @(
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
    $RoutingDriftStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$requiredAction = if ($materialDriftDetected) {
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
    'continue-monitoring'
}

$acceptedEvidenceHash = (Get-FileHash -LiteralPath $resolvedAcceptedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$acceptedEvidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedAcceptedEvidencePath).Replace('\', '/')
$integrity = [ordered]@{
    acceptedFullTrafficEvidenceSha256 = $acceptedEvidenceHash
    acceptedFullTrafficEvidenceIntegrityDigest = [string]$acceptedEvidence.integrityDigest
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    nextReviewDueAtUtc = $nextReviewDueAt.ToUniversalTime().ToString('o')
    reviewIntervalMinutes = $ReviewIntervalMinutes
    productionContext = $ExpectedProductionContext
    releaseVersion = [string]$acceptedEvidence.candidate.version
    sourceTag = [string]$acceptedEvidence.candidate.sourceTag
    controlPlaneImage = [string]$acceptedEvidence.candidate.controlPlaneImage
    edgeImage = [string]$acceptedEvidence.candidate.edgeImage
    policyVersion = [string]$acceptedEvidence.candidate.policyVersion
    trafficController = [string]$acceptedEvidence.traffic.controller
    observedTrafficPercent = $ObservedTrafficPercent
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
    trafficStateReference = $TrafficStateReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    driftEvidenceReference = $DriftEvidenceReference
    reviewedBy = $ReviewedBy
    reacceptanceRequired = $materialDriftDetected
    requiredAction = $requiredAction
    outcome = $outcome
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'ongoing-production-assurance'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    acceptedFullTrafficEvidence = [ordered]@{
        relativePath = $acceptedEvidenceRelativePath
        sha256 = $acceptedEvidenceHash
        integrityDigest = [string]$acceptedEvidence.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$acceptedEvidence.collectedAtUtc).ToUniversalTime().ToString('o')
        outcome = [string]$acceptedEvidence.outcome
    }
    candidate = [ordered]@{
        version = [string]$acceptedEvidence.candidate.version
        sourceTag = [string]$acceptedEvidence.candidate.sourceTag
        controlPlaneImage = [string]$acceptedEvidence.candidate.controlPlaneImage
        edgeImage = [string]$acceptedEvidence.candidate.edgeImage
        policyVersion = [string]$acceptedEvidence.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$acceptedEvidence.traffic.controller
        observedTrafficPercent = $ObservedTrafficPercent
        externallyEnforced = $true
    }
    schedule = [ordered]@{
        reviewIntervalMinutes = $ReviewIntervalMinutes
        nextReviewDueAtUtc = $nextReviewDueAt.ToUniversalTime().ToString('o')
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
    externalEvidence = [ordered]@{
        trafficStateReference = $TrafficStateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        driftEvidenceReference = $DriftEvidenceReference
        reviewedBy = $ReviewedBy
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    decision = [ordered]@{
        reacceptanceRequired = $materialDriftDetected
        requiredAction = $requiredAction
    }
    rollback = [ordered]@{
        mode = [string]$acceptedEvidence.rollback.mode
        targetPercent = [int]$acceptedEvidence.rollback.targetPercent
        emergencyTargetPercent = [int]$acceptedEvidence.rollback.emergencyTargetPercent
        authority = [string]$acceptedEvidence.rollback.authority
        procedureReference = [string]$acceptedEvidence.rollback.procedureReference
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'assurance-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production assurance evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production assurance evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Required action: $requiredAction"
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Ongoing assurance is blocked. Follow the recorded action through the authoritative change or incident system.'
}
