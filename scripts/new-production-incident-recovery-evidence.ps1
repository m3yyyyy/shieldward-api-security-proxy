[CmdletBinding()]
param(
    [string]$RecoveryPlanPath = '.shieldward/production-incident-recovery/recovery.json',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ExecutedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(0, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$TrafficEnforcementStatus,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$WorkloadVerificationStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'failed', 'unknown')]
    [string]$RecoveryExecutionStatus,

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
    [string]$DriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'expiring', 'invalid', 'unknown')]
    [string]$CertificateStatus,

    [Parameter(Mandatory)]
    [ValidateSet('ready', 'not-ready', 'unknown')]
    [string]$RollbackReadinessStatus,

    [Parameter(Mandatory)]
    [ValidateSet('updated', 'missing', 'unknown')]
    [string]$IncidentRecordStatus,

    [Parameter(Mandatory)]
    [ValidateSet('updated', 'missing', 'unknown')]
    [string]$RecoveryChangeRecordStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryExecutionReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryGateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MonitoringEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RollbackEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryChangeRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectedBy,

    [ValidateRange(5, 1440)]
    [int]$MaxExecutionAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery-evidence',
    [switch]$CheckCluster,
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
    [pscustomobject]@{ Value = $WorkloadEvidenceReference; Description = 'WorkloadEvidenceReference' }
    [pscustomobject]@{ Value = $RecoveryExecutionReference; Description = 'RecoveryExecutionReference' }
    [pscustomobject]@{ Value = $RecoveryGateReference; Description = 'RecoveryGateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackEvidenceReference; Description = 'RollbackEvidenceReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $RecoveryChangeRecordReference; Description = 'RecoveryChangeRecordReference' }
    [pscustomobject]@{ Value = $CollectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $RecoveryPlanPath -Description 'RecoveryPlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    $planValidationArguments.ContainmentEvidencePath = $ContainmentEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $planValidationArguments.ResponsePlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
$expiresAt = [DateTimeOffset]$plan.expiresAtUtc
$executedAt = $ExecutedAtUtc.ToUniversalTime()
$now = [DateTimeOffset]::UtcNow
$executionAge = $now - $executedAt
if (
    $executedAt -lt $approvedAt.ToUniversalTime() -or
    $executedAt -gt $expiresAt.ToUniversalTime() -or
    $executionAge.TotalMinutes -lt -5 -or
    $executionAge.TotalMinutes -gt $MaxExecutionAgeMinutes
) {
    throw "ExecutedAtUtc must follow approval, precede plan expiry, and be within $MaxExecutionAgeMinutes minutes of current UTC time."
}

$expectedTrafficPercent = [int]$plan.traffic.targetPercent
$trafficMatchesPlan = $ObservedTrafficPercent -eq $expectedTrafficPercent
$hasFailure = (
    $TrafficEnforcementStatus -eq 'failed' -or
    $WorkloadVerificationStatus -eq 'failed' -or
    $RecoveryExecutionStatus -eq 'failed' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident' -or
    $DriftStatus -eq 'detected' -or
    $CertificateStatus -in @('expiring', 'invalid') -or
    $RollbackReadinessStatus -eq 'not-ready' -or
    $IncidentRecordStatus -eq 'missing' -or
    $RecoveryChangeRecordStatus -eq 'missing' -or
    -not $trafficMatchesPlan
)
$hasUnknown = @(
    $TrafficEnforcementStatus,
    $WorkloadVerificationStatus,
    $RecoveryExecutionStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus,
    $CapacityStatus,
    $SecurityStatus,
    $DriftStatus,
    $CertificateStatus,
    $RollbackReadinessStatus,
    $IncidentRecordStatus,
    $RecoveryChangeRecordStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$targetReached = $outcome -eq 'passed'
$fullTrafficRestored = $targetReached -and $expectedTrafficPercent -eq 100
$nextAction = if ($outcome -ne 'passed') {
    'restore-contained-boundary-and-escalate'
}
elseif ($expectedTrafficPercent -lt 100) {
    'observe-recovery-canary-before-expansion'
}
else {
    'resume-continuous-production-assurance'
}

$collectedAt = [DateTimeOffset]::UtcNow
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$integrity = [ordered]@{
    recoveryPlanSha256 = $planHash
    recoveryPlanIntegrityDigest = [string]$plan.integrityDigest
    recoveryPlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    recoveryMode = [string]$plan.recovery.mode
    trafficController = [string]$plan.traffic.controller
    containedTrafficPercent = [int]$plan.traffic.currentPercent
    expectedTrafficPercent = $expectedTrafficPercent
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = $TrafficEnforcementStatus
    workloadVerificationStatus = $WorkloadVerificationStatus
    recoveryExecutionStatus = $RecoveryExecutionStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    capacityStatus = $CapacityStatus
    securityStatus = $SecurityStatus
    driftStatus = $DriftStatus
    certificateStatus = $CertificateStatus
    rollbackReadinessStatus = $RollbackReadinessStatus
    incidentRecordStatus = $IncidentRecordStatus
    recoveryChangeRecordStatus = $RecoveryChangeRecordStatus
    executedAtUtc = $executedAt.ToString('o')
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    trafficStateReference = $TrafficStateReference
    workloadEvidenceReference = $WorkloadEvidenceReference
    recoveryExecutionReference = $RecoveryExecutionReference
    recoveryGateReference = $RecoveryGateReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    rollbackEvidenceReference = $RollbackEvidenceReference
    incidentRecordReference = $IncidentRecordReference
    recoveryChangeRecordReference = $RecoveryChangeRecordReference
    collectedBy = $CollectedBy
    targetReached = $targetReached
    fullTrafficRestored = $fullTrafficRestored
    outcome = $outcome
    nextAction = $nextAction
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'incident-recovery-execution'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    recoveryPlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        approvedAtUtc = $approvedAt.ToUniversalTime().ToString('o')
        expiresAtUtc = $expiresAt.ToUniversalTime().ToString('o')
        state = [string]$plan.state
    }
    candidate = [ordered]@{
        version = [string]$plan.candidate.version
        sourceTag = [string]$plan.candidate.sourceTag
        controlPlaneImage = [string]$plan.candidate.controlPlaneImage
        edgeImage = [string]$plan.candidate.edgeImage
        policyVersion = [string]$plan.candidate.policyVersion
    }
    execution = [ordered]@{
        mode = [string]$plan.recovery.mode
        owner = [string]$plan.recovery.owner
        status = $RecoveryExecutionStatus
        executedAtUtc = $executedAt.ToString('o')
    }
    traffic = [ordered]@{
        controller = [string]$plan.traffic.controller
        containedPercent = [int]$plan.traffic.currentPercent
        expectedPercent = $expectedTrafficPercent
        observedPercent = $ObservedTrafficPercent
        matchesPlan = $trafficMatchesPlan
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
    }
    verification = [ordered]@{
        workloads = $WorkloadVerificationStatus
        functional = $FunctionalStatus
        dependencies = $DependencyStatus
        operations = $OperationalStatus
        capacity = $CapacityStatus
        security = $SecurityStatus
        drift = $DriftStatus
        certificates = $CertificateStatus
        rollbackReadiness = $RollbackReadinessStatus
        incidentRecord = $IncidentRecordStatus
        recoveryChangeRecord = $RecoveryChangeRecordStatus
    }
    externalEvidence = [ordered]@{
        trafficStateReference = $TrafficStateReference
        workloadEvidenceReference = $WorkloadEvidenceReference
        recoveryExecutionReference = $RecoveryExecutionReference
        recoveryGateReference = $RecoveryGateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        rollbackEvidenceReference = $RollbackEvidenceReference
        incidentRecordReference = $IncidentRecordReference
        recoveryChangeRecordReference = $RecoveryChangeRecordReference
        collectedBy = $CollectedBy
    }
    rollback = [ordered]@{
        targetPercent = [int]$plan.rollback.targetPercent
        emergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
        authority = [string]$plan.rollback.authority
        procedureReference = [string]$plan.rollback.procedureReference
        readinessStatus = $RollbackReadinessStatus
    }
    decision = [ordered]@{
        targetReached = $targetReached
        fullTrafficRestored = $fullTrafficRestored
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'recovery-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production incident recovery evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production incident recovery evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Observed recovery boundary: $ObservedTrafficPercent%; next action: $nextAction"
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Recovery is not proven. Restore the contained boundary through the authoritative controller and escalate.'
}
