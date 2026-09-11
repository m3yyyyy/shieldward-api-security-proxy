[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryEvidencePath,

    [string]$RecoveryPlanPath = '',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$ExpansionChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalOwner,

    [Parameter(Mandatory)]
    [ValidateRange(2, 25)]
    [int]$TargetPercent,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ObservationStartedAtUtc,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ObservationEndedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(1, 10)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('stable', 'degraded', 'unknown')]
    [string]$TrafficStabilityStatus,

    [Parameter(Mandatory)]
    [ValidateSet('stable', 'degraded', 'unknown')]
    [string]$WorkloadStatus,

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
    [ValidateSet('approved', 'pending', 'rejected', 'unknown')]
    [string]$ExpansionChangeStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryEvidenceGateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficObservationReference,

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
    [string]$ExpansionChangeReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewedBy,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxRecoveryEvidenceAgeMinutes = 60,

    [ValidateRange(5, 1440)]
    [int]$PlanValidityMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery-expansion',
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

function Assert-OperatorValue {
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

foreach ($value in @(
    [pscustomobject]@{ Value = $ApprovalOwner; Description = 'ApprovalOwner' }
    [pscustomobject]@{ Value = $RecoveryEvidenceGateReference; Description = 'RecoveryEvidenceGateReference' }
    [pscustomobject]@{ Value = $TrafficObservationReference; Description = 'TrafficObservationReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackEvidenceReference; Description = 'RollbackEvidenceReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $ExpansionChangeReference; Description = 'ExpansionChangeReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-OperatorValue -Value $value.Value -Description $value.Description
}

$resolvedEvidencePath = Resolve-LocalStatePath -Path $RecoveryEvidencePath -Description 'RecoveryEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production incident recovery execution evidence is missing: $resolvedEvidencePath"
}
$evidenceValidationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($RecoveryPlanPath)) {
    $evidenceValidationArguments.RecoveryPlanPath = $RecoveryPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    $evidenceValidationArguments.ContainmentEvidencePath = $ContainmentEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $evidenceValidationArguments.ResponsePlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-evidence.ps1') @evidenceValidationArguments 6>$null

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'Only passed, externally enforced recovery execution evidence may begin re-expansion planning.'
}

$currentPercent = [int]$evidence.traffic.observedPercent
if ($currentPercent -lt 1 -or $currentPercent -gt 10) {
    throw 'Recovery re-expansion requires an externally enforced 1-10 percent recovery canary.'
}
if ($ObservedTrafficPercent -ne $currentPercent) {
    throw "ObservedTrafficPercent must remain at the proven recovery canary of $currentPercent percent."
}
if ($TargetPercent -le $currentPercent -or $TargetPercent -gt 25) {
    throw "TargetPercent must increase the recovery canary from $currentPercent% without exceeding 25 percent."
}
if ([string]::Equals($ExpansionChangeId, [string]$evidence.recoveryChangeId, [StringComparison]::Ordinal)) {
    throw 'ExpansionChangeId must identify a separate recovery expansion change record.'
}

$executedAt = ([DateTimeOffset]$evidence.execution.executedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$observationStartedAt = $ObservationStartedAtUtc.ToUniversalTime()
$observationEndedAt = $ObservationEndedAtUtc.ToUniversalTime()
$observationDuration = $observationEndedAt - $observationStartedAt
$evidenceAge = $referenceNow - $collectedAt
$observationAge = $referenceNow - $observationEndedAt
if (
    $observationStartedAt -lt $executedAt -or
    $observationEndedAt -lt $collectedAt -or
    $observationEndedAt -lt $observationStartedAt -or
    $observationDuration.TotalMinutes -lt $ObservationMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt $MaxRecoveryEvidenceAgeMinutes -or
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxRecoveryEvidenceAgeMinutes
) {
    throw 'The recovery canary observation window is incomplete, future-dated, stale, or precedes recovery execution evidence.'
}

$hasFailure = (
    $TrafficStabilityStatus -eq 'degraded' -or
    $WorkloadStatus -eq 'degraded' -or
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
    $ExpansionChangeStatus -eq 'rejected'
)
$hasUnknown = @(
    $TrafficStabilityStatus,
    $WorkloadStatus,
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
    $ExpansionChangeStatus
) -contains 'unknown'
if ($ExpansionChangeStatus -eq 'pending') {
    $hasUnknown = $true
}
$readinessOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$nextAction = switch ($readinessOutcome) {
    'passed' { 'await-independent-recovery-expansion-approval' }
    'failed' { 'restore-recovery-canary-and-escalate' }
    default { 'hold-recovery-canary-and-collect-evidence' }
}
$state = if ($readinessOutcome -eq 'passed') { 'pending' } else { 'blocked' }

$generatedAt = $referenceNow
$expiresAt = $generatedAt.AddMinutes($PlanValidityMinutes)
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE RECOVERY EXPANSION TO $TargetPercent% $ExpansionChangeId FOR $ExpectedProductionContext INCIDENT $($evidence.incidentId) RELEASE $($evidence.candidate.version)"

$integrity = [ordered]@{
    recoveryEvidenceSha256 = $evidenceHash
    recoveryEvidenceIntegrityDigest = [string]$evidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$evidence.incidentId
    containmentChangeId = [string]$evidence.containmentChangeId
    recoveryChangeId = [string]$evidence.recoveryChangeId
    expansionChangeId = $ExpansionChangeId
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    planValidityMinutes = $PlanValidityMinutes
    maxRecoveryEvidenceAgeMinutes = $MaxRecoveryEvidenceAgeMinutes
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    currentTrafficPercent = $currentPercent
    targetTrafficPercent = $TargetPercent
    maximumTargetPercent = 25
    observationStartedAtUtc = $observationStartedAt.ToString('o')
    observationEndedAtUtc = $observationEndedAt.ToString('o')
    observationMinutes = $ObservationMinutes
    observedTrafficPercent = $ObservedTrafficPercent
    trafficStabilityStatus = $TrafficStabilityStatus
    workloadStatus = $WorkloadStatus
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
    rollbackAuthority = [string]$evidence.rollback.authority
    rollbackProcedureReference = [string]$evidence.rollback.procedureReference
    incidentRecordStatus = $IncidentRecordStatus
    expansionChangeStatus = $ExpansionChangeStatus
    recoveryEvidenceGateReference = $RecoveryEvidenceGateReference
    trafficObservationReference = $TrafficObservationReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    rollbackEvidenceReference = $RollbackEvidenceReference
    incidentRecordReference = $IncidentRecordReference
    expansionChangeReference = $ExpansionChangeReference
    approvalOwner = $ApprovalOwner
    reviewedBy = $ReviewedBy
    readinessOutcome = $readinessOutcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'incident-recovery-canary-expansion'
    state = $state
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    planValidityMinutes = $PlanValidityMinutes
    maxRecoveryEvidenceAgeMinutes = $MaxRecoveryEvidenceAgeMinutes
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$evidence.incidentId
    containmentChangeId = [string]$evidence.containmentChangeId
    recoveryChangeId = [string]$evidence.recoveryChangeId
    expansionChangeId = $ExpansionChangeId
    recoveryEvidence = [ordered]@{
        relativePath = $evidenceRelativePath
        sha256 = $evidenceHash
        integrityDigest = [string]$evidence.integrityDigest
        collectedAtUtc = $collectedAt.ToString('o')
        executedAtUtc = $executedAt.ToString('o')
        outcome = [string]$evidence.outcome
    }
    candidate = [ordered]@{
        version = [string]$evidence.candidate.version
        sourceTag = [string]$evidence.candidate.sourceTag
        controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
        edgeImage = [string]$evidence.candidate.edgeImage
        policyVersion = [string]$evidence.candidate.policyVersion
    }
    observation = [ordered]@{
        startedAtUtc = $observationStartedAt.ToString('o')
        endedAtUtc = $observationEndedAt.ToString('o')
        minimumMinutes = $ObservationMinutes
        observedTrafficPercent = $ObservedTrafficPercent
        trafficStability = $TrafficStabilityStatus
        workloads = $WorkloadStatus
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
        expansionChange = $ExpansionChangeStatus
    }
    traffic = [ordered]@{
        controller = [string]$evidence.traffic.controller
        currentPercent = $currentPercent
        targetPercent = $TargetPercent
        maximumTargetPercent = 25
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = 'restore-recovery-canary-or-disable'
        targetPercent = $currentPercent
        emergencyTargetPercent = 0
        authority = [string]$evidence.rollback.authority
        procedureReference = [string]$evidence.rollback.procedureReference
        readinessStatus = $RollbackReadinessStatus
    }
    externalEvidence = [ordered]@{
        recoveryEvidenceGateReference = $RecoveryEvidenceGateReference
        trafficObservationReference = $TrafficObservationReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        rollbackEvidenceReference = $RollbackEvidenceReference
        incidentRecordReference = $IncidentRecordReference
        expansionChangeReference = $ExpansionChangeReference
        reviewedBy = $ReviewedBy
    }
    execution = [ordered]@{
        state = 'not-started'
        externalTrafficControllerRequired = $true
    }
    readiness = [ordered]@{
        outcome = $readinessOutcome
    }
    approval = [ordered]@{
        status = if ($state -eq 'pending') { 'pending' } else { 'blocked' }
        owner = $ApprovalOwner
        requiredStatement = $requiredApprovalStatement
        approvedBy = $null
        approvedAtUtc = $null
        approvedAtUnixSeconds = $null
        approvalStatement = $null
        approvalDigest = $null
    }
    decision = [ordered]@{
        nextAction = $nextAction
        afterApprovalAction = 'execute-approved-recovery-expansion-externally'
        holdTrafficAtPercent = $currentPercent
    }
    safeguards = @(
        'passed-immutable-recovery-execution-evidence'
        'completed-bounded-recovery-canary-observation'
        'healthy-error-budget-and-operational-signals'
        'separate-recovery-expansion-change-record'
        'separate-exact-expansion-approval'
        'maximum-twenty-five-percent-traffic'
        'external-traffic-enforcement'
        'rollback-to-recovery-canary'
        'emergency-disable-to-zero'
        'no-automatic-production-mutation'
        'preserve-incident-audit-evidence'
    )
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'expansion.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production incident recovery expansion plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production recovery canary observation recorded with readiness '$readinessOutcome'."
Write-Host "Pending recovery expansion from $currentPercent% to $TargetPercent% recorded at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
if ($readinessOutcome -ne 'passed') {
    Write-Warning 'Recovery expansion is blocked. Hold or restore the recovery canary and preserve evidence.'
}
