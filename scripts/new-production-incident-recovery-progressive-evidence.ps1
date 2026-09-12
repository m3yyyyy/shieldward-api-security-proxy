[CmdletBinding()]
param(
    [string]$ProgressivePlanPath = '.shieldward/production-incident-recovery-progressive/expansion.json',
    [string]$ExpansionEvidencePath = '',
    [string]$ExpansionPlanPath = '',
    [string]$RecoveryEvidencePath = '',
    [string]$RecoveryPlanPath = '',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ExecutedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(3, 50)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$TrafficEnforcementStatus,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$WorkloadVerificationStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'failed', 'unknown')]
    [string]$ProgressiveExecutionStatus,

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
    [string]$ProgressiveChangeRecordStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProgressiveExecutionReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProgressiveGateReference,

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
    [string]$ProgressiveChangeRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectedBy,

    [ValidateRange(5, 1440)]
    [int]$MaxExecutionAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery-progressive-evidence',
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

foreach ($reference in @(
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $WorkloadEvidenceReference; Description = 'WorkloadEvidenceReference' }
    [pscustomobject]@{ Value = $ProgressiveExecutionReference; Description = 'ProgressiveExecutionReference' }
    [pscustomobject]@{ Value = $ProgressiveGateReference; Description = 'ProgressiveGateReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackEvidenceReference; Description = 'RollbackEvidenceReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $ProgressiveChangeRecordReference; Description = 'ProgressiveChangeRecordReference' }
    [pscustomobject]@{ Value = $CollectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $ProgressivePlanPath -Description 'ProgressivePlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery progressive plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'RecoveryEvidencePath'; Value = $RecoveryEvidencePath }
    [pscustomobject]@{ Name = 'RecoveryPlanPath'; Value = $RecoveryPlanPath }
    [pscustomobject]@{ Name = 'ContainmentEvidencePath'; Value = $ContainmentEvidencePath }
    [pscustomobject]@{ Name = 'ResponsePlanPath'; Value = $ResponsePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $planValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $planValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$executedAt = $ExecutedAtUtc.ToUniversalTime()
$executionAge = $referenceNow - $executedAt
if (
    $executedAt -lt $approvedAt -or
    $executedAt -gt $expiresAt -or
    $executionAge.TotalMinutes -lt -5 -or
    $executionAge.TotalMinutes -gt $MaxExecutionAgeMinutes
) {
    throw "ExecutedAtUtc must follow approval, precede plan expiry, and be within $MaxExecutionAgeMinutes minutes of the current reference time."
}

$expectedTrafficPercent = [int]$plan.traffic.targetPercent
$trafficMatchesPlan = $ObservedTrafficPercent -eq $expectedTrafficPercent
$hasFailure = (
    $TrafficEnforcementStatus -eq 'failed' -or
    $WorkloadVerificationStatus -eq 'failed' -or
    $ProgressiveExecutionStatus -eq 'failed' -or
    $ErrorBudgetStatus -eq 'exhausted' -or
    $AlertStatus -eq 'firing' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident' -or
    $DriftStatus -eq 'detected' -or
    $CertificateStatus -in @('expiring', 'invalid') -or
    $RollbackReadinessStatus -eq 'not-ready' -or
    $IncidentRecordStatus -eq 'missing' -or
    $ProgressiveChangeRecordStatus -eq 'missing' -or
    -not $trafficMatchesPlan
)
$hasUnknown = @(
    $TrafficEnforcementStatus,
    $WorkloadVerificationStatus,
    $ProgressiveExecutionStatus,
    $ErrorBudgetStatus,
    $AlertStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus,
    $CapacityStatus,
    $SecurityStatus,
    $DriftStatus,
    $CertificateStatus,
    $RollbackReadinessStatus,
    $IncidentRecordStatus,
    $ProgressiveChangeRecordStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$targetReached = $outcome -eq 'passed'
$nextAction = switch ($outcome) {
    'passed' { 'observe-recovery-progressive-expansion-before-next-step' }
    'failed' { 'restore-previous-recovery-boundary-and-escalate' }
    default { 'hold-safest-recovery-boundary-and-collect-evidence' }
}

$collectedAt = $referenceNow
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$integrity = [ordered]@{
    progressivePlanSha256 = $planHash
    progressivePlanIntegrityDigest = [string]$plan.integrityDigest
    progressivePlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    trafficController = [string]$plan.traffic.controller
    previousBoundaryPercent = [int]$plan.traffic.currentPercent
    expectedTrafficPercent = $expectedTrafficPercent
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = $TrafficEnforcementStatus
    workloadVerificationStatus = $WorkloadVerificationStatus
    progressiveExecutionStatus = $ProgressiveExecutionStatus
    errorBudgetStatus = $ErrorBudgetStatus
    alertStatus = $AlertStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    capacityStatus = $CapacityStatus
    securityStatus = $SecurityStatus
    driftStatus = $DriftStatus
    certificateStatus = $CertificateStatus
    rollbackReadinessStatus = $RollbackReadinessStatus
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    incidentRecordStatus = $IncidentRecordStatus
    progressiveChangeRecordStatus = $ProgressiveChangeRecordStatus
    executedAtUtc = $executedAt.ToString('o')
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    trafficStateReference = $TrafficStateReference
    workloadEvidenceReference = $WorkloadEvidenceReference
    progressiveExecutionReference = $ProgressiveExecutionReference
    progressiveGateReference = $ProgressiveGateReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    rollbackEvidenceReference = $RollbackEvidenceReference
    incidentRecordReference = $IncidentRecordReference
    progressiveChangeRecordReference = $ProgressiveChangeRecordReference
    collectedBy = $CollectedBy
    targetReached = $targetReached
    outcome = $outcome
    nextAction = $nextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'incident-recovery-progressive-execution'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    progressivePlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        approvedAtUtc = $approvedAt.ToString('o')
        expiresAtUtc = $expiresAt.ToString('o')
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
        status = $ProgressiveExecutionStatus
        executedAtUtc = $executedAt.ToString('o')
    }
    traffic = [ordered]@{
        controller = [string]$plan.traffic.controller
        previousBoundaryPercent = [int]$plan.traffic.currentPercent
        expectedPercent = $expectedTrafficPercent
        observedPercent = $ObservedTrafficPercent
        matchesPlan = $trafficMatchesPlan
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
    }
    verification = [ordered]@{
        workloads = $WorkloadVerificationStatus
        errorBudget = $ErrorBudgetStatus
        alerts = $AlertStatus
        functional = $FunctionalStatus
        dependencies = $DependencyStatus
        operations = $OperationalStatus
        capacity = $CapacityStatus
        security = $SecurityStatus
        drift = $DriftStatus
        certificates = $CertificateStatus
        rollbackReadiness = $RollbackReadinessStatus
        incidentRecord = $IncidentRecordStatus
        progressiveChangeRecord = $ProgressiveChangeRecordStatus
    }
    externalEvidence = [ordered]@{
        trafficStateReference = $TrafficStateReference
        workloadEvidenceReference = $WorkloadEvidenceReference
        progressiveExecutionReference = $ProgressiveExecutionReference
        progressiveGateReference = $ProgressiveGateReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        rollbackEvidenceReference = $RollbackEvidenceReference
        incidentRecordReference = $IncidentRecordReference
        progressiveChangeRecordReference = $ProgressiveChangeRecordReference
        collectedBy = $CollectedBy
    }
    rollback = [ordered]@{
        mode = [string]$plan.rollback.mode
        targetPercent = [int]$plan.rollback.targetPercent
        emergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
        authority = [string]$plan.rollback.authority
        procedureReference = [string]$plan.rollback.procedureReference
        readinessStatus = $RollbackReadinessStatus
    }
    decision = [ordered]@{
        targetReached = $targetReached
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'progressive-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production incident recovery progressive evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production recovery progressive evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Observed recovery progressive expansion boundary: $ObservedTrafficPercent%; next action: $nextAction"
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Recovery progressive expansion is not proven. Hold or restore the previous recovery boundary through the authoritative controller and escalate.'
}
