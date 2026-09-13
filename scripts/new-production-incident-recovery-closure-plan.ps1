[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FinalExpansionEvidencePath,

    [string]$FinalExpansionPlanPath = '',
    [string]$SecondExpansionEvidencePath = '',
    [string]$SecondExpansionPlanPath = '',
    [string]$ProgressiveEvidencePath = '',
    [string]$ProgressivePlanPath = '',
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
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$ClosureChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalOwner,

    [Parameter(Mandatory)]
    [ValidateRange(76, 100)]
    [int]$HoldTrafficPercent,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ObservationStartedAtUtc,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ObservationEndedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(51, 100)]
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
    [ValidateSet('passed', 'failed', 'unknown')]
    [string]$ReacceptanceStatus,

    [Parameter(Mandatory)]
    [ValidateSet('updated', 'missing', 'unknown')]
    [string]$IncidentRecordStatus,

    [Parameter(Mandatory)]
    [ValidateSet('approved', 'pending', 'rejected', 'unknown')]
    [string]$ClosureChangeStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PreviousExecutionGateReference,

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
    [string]$ReacceptanceEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClosureChangeReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewedBy,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxFinalExpansionEvidenceAgeMinutes = 60,

    [ValidateRange(5, 1440)]
    [int]$PlanValidityMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery-closure',
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
    [pscustomobject]@{ Value = $PreviousExecutionGateReference; Description = 'PreviousExecutionGateReference' }
    [pscustomobject]@{ Value = $TrafficObservationReference; Description = 'TrafficObservationReference' }
    [pscustomobject]@{ Value = $MonitoringEvidenceReference; Description = 'MonitoringEvidenceReference' }
    [pscustomobject]@{ Value = $RollbackEvidenceReference; Description = 'RollbackEvidenceReference' }
    [pscustomobject]@{ Value = $ReacceptanceEvidenceReference; Description = 'ReacceptanceEvidenceReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $ClosureChangeReference; Description = 'ClosureChangeReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-OperatorValue -Value $value.Value -Description $value.Description
}

$resolvedEvidencePath = Resolve-LocalStatePath -Path $FinalExpansionEvidencePath -Description 'FinalExpansionEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production incident recovery final expansion execution evidence is missing: $resolvedEvidencePath"
}
$evidenceValidationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($FinalExpansionPlanPath)) {
    $evidenceValidationArguments.FinalExpansionPlanPath = $FinalExpansionPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($SecondExpansionEvidencePath)) {
    $evidenceValidationArguments.SecondExpansionEvidencePath = $SecondExpansionEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($SecondExpansionPlanPath)) {
    $evidenceValidationArguments.SecondExpansionPlanPath = $SecondExpansionPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ProgressiveEvidencePath)) {
    $evidenceValidationArguments.ProgressiveEvidencePath = $ProgressiveEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ProgressivePlanPath)) {
    $evidenceValidationArguments.ProgressivePlanPath = $ProgressivePlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ExpansionEvidencePath)) {
    $evidenceValidationArguments.ExpansionEvidencePath = $ExpansionEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ExpansionPlanPath)) {
    $evidenceValidationArguments.ExpansionPlanPath = $ExpansionPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($RecoveryEvidencePath)) {
    $evidenceValidationArguments.RecoveryEvidencePath = $RecoveryEvidencePath
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
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $evidenceValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-final-expansion-evidence.ps1') @evidenceValidationArguments 6>$null

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'Only passed, externally enforced recovery final expansion execution evidence may begin incident-closure planning.'
}

$currentPercent = [int]$evidence.traffic.observedPercent
if ($currentPercent -ne 100) {
    throw 'Recovery incident-closure planning requires an externally enforced 100 percent boundary.'
}
if ($ObservedTrafficPercent -ne $currentPercent) {
    throw "ObservedTrafficPercent must remain at the proven final recovery boundary of $currentPercent percent."
}
if ($HoldTrafficPercent -ne 100) {
    throw 'HoldTrafficPercent must be exactly 100 percent; closure planning cannot mutate traffic.'
}
if (@(
    [string]$evidence.containmentChangeId,
    [string]$evidence.recoveryChangeId,
    [string]$evidence.expansionChangeId,
    [string]$evidence.progressiveChangeId,
    [string]$evidence.finalExpansionChangeId
) -contains $ClosureChangeId) {
    throw 'ClosureChangeId must identify a separate recovery incident-closure change record.'
}
if (
    [int]$evidence.rollback.targetPercent -ne 75 -or
    [int]$evidence.rollback.emergencyTargetPercent -ne 0
) {
    throw 'Recovery incident-closure planning requires rollback to 75 percent and emergency disable-to-zero.'
}
if ([string]::Equals($ReviewedBy, $ApprovalOwner, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReviewedBy must identify an independent reviewer distinct from ApprovalOwner.'
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
    $observationAge.TotalMinutes -gt $MaxFinalExpansionEvidenceAgeMinutes -or
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxFinalExpansionEvidenceAgeMinutes
) {
    throw 'The incident-closure observation window is incomplete, future-dated, stale, or precedes final expansion execution evidence.'
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
    $ReacceptanceStatus -eq 'failed' -or
    $IncidentRecordStatus -eq 'missing' -or
    $ClosureChangeStatus -eq 'rejected'
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
    $ReacceptanceStatus,
    $IncidentRecordStatus,
    $ClosureChangeStatus
) -contains 'unknown'
if ($ClosureChangeStatus -eq 'pending') {
    $hasUnknown = $true
}
$readinessOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$nextAction = switch ($readinessOutcome) {
    'passed' { 'await-independent-recovery-incident-closure-approval' }
    'failed' { 'restore-previous-recovery-boundary-and-escalate' }
    default { 'hold-recovery-boundary-and-collect-evidence' }
}
$state = if ($readinessOutcome -eq 'passed') { 'pending' } else { 'blocked' }

$generatedAt = $referenceNow
$expiresAt = $generatedAt.AddMinutes($PlanValidityMinutes)
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE RECOVERY INCIDENT CLOSURE $ClosureChangeId FOR $ExpectedProductionContext INCIDENT $($evidence.incidentId) RELEASE $($evidence.candidate.version)"

$integrity = [ordered]@{
    finalExpansionEvidenceSha256 = $evidenceHash
    finalExpansionEvidenceIntegrityDigest = [string]$evidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$evidence.incidentId
    containmentChangeId = [string]$evidence.containmentChangeId
    recoveryChangeId = [string]$evidence.recoveryChangeId
    expansionChangeId = [string]$evidence.expansionChangeId
    progressiveChangeId = [string]$evidence.progressiveChangeId
    finalExpansionChangeId = [string]$evidence.finalExpansionChangeId
    closureChangeId = $ClosureChangeId
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    planValidityMinutes = $PlanValidityMinutes
    maxFinalExpansionEvidenceAgeMinutes = $MaxFinalExpansionEvidenceAgeMinutes
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    currentTrafficPercent = $currentPercent
    holdTrafficPercent = $HoldTrafficPercent
    requiredHoldPercent = 100
    trafficMutationPercentagePoints = 0
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
    reacceptanceStatus = $ReacceptanceStatus
    rollbackTargetPercent = [int]$evidence.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$evidence.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$evidence.rollback.authority
    rollbackProcedureReference = [string]$evidence.rollback.procedureReference
    incidentRecordStatus = $IncidentRecordStatus
    closureChangeStatus = $ClosureChangeStatus
    previousExecutionGateReference = $PreviousExecutionGateReference
    trafficObservationReference = $TrafficObservationReference
    monitoringEvidenceReference = $MonitoringEvidenceReference
    rollbackEvidenceReference = $RollbackEvidenceReference
    reacceptanceEvidenceReference = $ReacceptanceEvidenceReference
    incidentRecordReference = $IncidentRecordReference
    closureChangeReference = $ClosureChangeReference
    approvalOwner = $ApprovalOwner
    reviewedBy = $ReviewedBy
    readinessOutcome = $readinessOutcome
    nextAction = $nextAction
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'incident-recovery-closure'
    state = $state
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    planValidityMinutes = $PlanValidityMinutes
    maxFinalExpansionEvidenceAgeMinutes = $MaxFinalExpansionEvidenceAgeMinutes
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$evidence.incidentId
    containmentChangeId = [string]$evidence.containmentChangeId
    recoveryChangeId = [string]$evidence.recoveryChangeId
    expansionChangeId = [string]$evidence.expansionChangeId
    progressiveChangeId = [string]$evidence.progressiveChangeId
    finalExpansionChangeId = [string]$evidence.finalExpansionChangeId
    closureChangeId = $ClosureChangeId
    finalExpansionEvidence = [ordered]@{
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
        reacceptance = $ReacceptanceStatus
        incidentRecord = $IncidentRecordStatus
        closureChange = $ClosureChangeStatus
    }
    traffic = [ordered]@{
        controller = [string]$evidence.traffic.controller
        currentPercent = $currentPercent
        holdPercent = $HoldTrafficPercent
        requiredHoldPercent = 100
        trafficMutationPercentagePoints = 0
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = 'restore-previous-recovery-boundary-or-disable'
        targetPercent = [int]$evidence.rollback.targetPercent
        emergencyTargetPercent = [int]$evidence.rollback.emergencyTargetPercent
        authority = [string]$evidence.rollback.authority
        procedureReference = [string]$evidence.rollback.procedureReference
        readinessStatus = $RollbackReadinessStatus
    }
    externalEvidence = [ordered]@{
        previousExecutionGateReference = $PreviousExecutionGateReference
        trafficObservationReference = $TrafficObservationReference
        monitoringEvidenceReference = $MonitoringEvidenceReference
        rollbackEvidenceReference = $RollbackEvidenceReference
        reacceptanceEvidenceReference = $ReacceptanceEvidenceReference
        incidentRecordReference = $IncidentRecordReference
        closureChangeReference = $ClosureChangeReference
        reviewedBy = $ReviewedBy
    }
    execution = [ordered]@{
        state = 'not-started'
        externalIncidentSystemRequired = $true
        trafficMutationAllowed = $false
        incidentClosurePerformed = $false
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
        afterApprovalAction = 'close-recovery-incident-externally-after-independent-review'
        holdTrafficAtPercent = $currentPercent
    }
    safeguards = @(
        'passed-immutable-recovery-final-expansion-execution-evidence'
        'completed-sustained-one-hundred-percent-observation'
        'passed-independent-production-reacceptance'
        'healthy-error-budget-and-operational-signals'
        'separate-recovery-incident-closure-change-record'
        'separate-exact-incident-closure-approval'
        'hold-one-hundred-percent-with-zero-traffic-mutation'
        'exactly-one-hundred-percent-traffic'
        'external-traffic-enforcement'
        'rollback-to-previous-recovery-boundary'
        'emergency-disable-to-zero'
        'no-automatic-production-mutation'
        'preserve-incident-audit-evidence'
    )
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'closure.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production incident recovery closure plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production recovery incident-closure observation recorded with readiness '$readinessOutcome'."
Write-Host "Pending incident-closure plan holding traffic at $HoldTrafficPercent% recorded at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
if ($readinessOutcome -ne 'passed') {
    Write-Warning 'Recovery incident closure is blocked. Hold the proven boundary, keep rollback ready, and preserve evidence.'
}
