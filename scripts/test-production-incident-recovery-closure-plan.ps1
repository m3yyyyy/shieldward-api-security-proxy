[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery-closure/closure.json',
    [string]$FinalExpansionEvidencePath = '',
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

    [ValidateSet('Pending', 'Approved', 'Any')]
    [string]$RequiredState = 'Approved',

    [switch]$CheckCluster,
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

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery closure plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'incident-recovery-closure'
) {
    throw 'The supplied production incident recovery closure plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The recovery incident closure plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The recovery incident closure plan uses unsupported namespace '$($plan.namespace)'."
}

$resolvedEvidencePath = if ([string]::IsNullOrWhiteSpace($FinalExpansionEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.finalExpansionEvidence.relativePath) -Description 'Recorded expansion evidence path'
}
else {
    Resolve-LocalStatePath -Path $FinalExpansionEvidencePath -Description 'FinalExpansionEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Recorded production incident recovery final expansion execution evidence is missing: $resolvedEvidencePath"
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
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $evidenceRelativePath -ne [string]$plan.finalExpansionEvidence.relativePath -or
    $evidenceHash -ne [string]$plan.finalExpansionEvidence.sha256 -or
    [string]$evidence.integrityDigest -ne [string]$plan.finalExpansionEvidence.integrityDigest -or
    [string]$evidence.outcome -ne 'passed' -or
    [string]$plan.finalExpansionEvidence.outcome -ne 'passed' -or
    [bool]$evidence.decision.targetReached -ne $true -or
    [bool]$evidence.traffic.externallyEnforced -ne $true
) {
    throw 'The passed immutable recovery final expansion execution evidence no longer matches the incident-closure plan.'
}

$currentPercent = [int]$evidence.traffic.observedPercent
$holdPercent = [int]$plan.traffic.holdPercent
if (
    $currentPercent -ne 100 -or
    [int]$plan.traffic.currentPercent -ne $currentPercent -or
    [int]$plan.observation.observedTrafficPercent -ne $currentPercent -or
    $holdPercent -ne 100 -or
    ($holdPercent - $currentPercent) -ne 0 -or
    [int]$plan.traffic.requiredHoldPercent -ne 100 -or
    [int]$plan.traffic.trafficMutationPercentagePoints -ne 0 -or
    [string]$plan.traffic.controller -ne [string]$evidence.traffic.controller -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true
) {
    throw 'Recovery incident-closure planning must hold the proven 100 percent boundary without mutating traffic.'
}
if (
    [string]$plan.incidentId -ne [string]$evidence.incidentId -or
    [string]$plan.containmentChangeId -ne [string]$evidence.containmentChangeId -or
    [string]$plan.recoveryChangeId -ne [string]$evidence.recoveryChangeId -or
    [string]$plan.expansionChangeId -ne [string]$evidence.expansionChangeId -or
    [string]$plan.progressiveChangeId -ne [string]$evidence.progressiveChangeId -or
    [string]$plan.finalExpansionChangeId -ne [string]$evidence.finalExpansionChangeId -or
    [string]::IsNullOrWhiteSpace([string]$plan.closureChangeId) -or
    @(
        [string]$plan.containmentChangeId,
        [string]$plan.recoveryChangeId,
        [string]$plan.expansionChangeId,
        [string]$plan.progressiveChangeId,
        [string]$plan.finalExpansionChangeId
    ) -contains [string]$plan.closureChangeId
) {
    throw 'The recovery incident closure identity or separate change record is invalid.'
}
if (
    [string]$plan.candidate.version -ne [string]$evidence.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$evidence.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$evidence.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$evidence.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$evidence.candidate.policyVersion
) {
    throw 'The recovery candidate does not match final expansion execution evidence.'
}
if (
    [string]$plan.rollback.mode -ne 'restore-previous-recovery-boundary-or-disable' -or
    [int]$plan.rollback.targetPercent -ne 75 -or
    [int]$plan.rollback.targetPercent -ne [int]$evidence.rollback.targetPercent -or
    [int]$plan.rollback.emergencyTargetPercent -ne 0 -or
    [int]$plan.rollback.emergencyTargetPercent -ne [int]$evidence.rollback.emergencyTargetPercent -or
    [string]$plan.rollback.authority -ne [string]$evidence.rollback.authority -or
    [string]$plan.rollback.procedureReference -ne [string]$evidence.rollback.procedureReference -or
    [string]$plan.rollback.readinessStatus -ne [string]$plan.observation.rollbackReadiness
) {
    throw 'The recovery incident-closure rollback boundary is invalid.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'traffic stability'; Actual = [string]$plan.observation.trafficStability; Allowed = @('stable', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'workloads'; Actual = [string]$plan.observation.workloads; Allowed = @('stable', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$plan.observation.errorBudget; Allowed = @('within-budget', 'exhausted', 'unknown') }
    [pscustomobject]@{ Name = 'alerts'; Actual = [string]$plan.observation.alerts; Allowed = @('clear', 'firing', 'unknown') }
    [pscustomobject]@{ Name = 'functional'; Actual = [string]$plan.observation.functional; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$plan.observation.dependencies; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$plan.observation.operations; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'capacity'; Actual = [string]$plan.observation.capacity; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'security'; Actual = [string]$plan.observation.security; Allowed = @('clear', 'incident', 'unknown') }
    [pscustomobject]@{ Name = 'drift'; Actual = [string]$plan.observation.drift; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'certificates'; Actual = [string]$plan.observation.certificates; Allowed = @('healthy', 'expiring', 'invalid', 'unknown') }
    [pscustomobject]@{ Name = 'rollback readiness'; Actual = [string]$plan.observation.rollbackReadiness; Allowed = @('ready', 'not-ready', 'unknown') }
    [pscustomobject]@{ Name = 'independent reacceptance'; Actual = [string]$plan.observation.reacceptance; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'incident record'; Actual = [string]$plan.observation.incidentRecord; Allowed = @('updated', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'incident closure change'; Actual = [string]$plan.observation.closureChange; Allowed = @('approved', 'pending', 'rejected', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The recovery incident closure plan contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($value in @(
    [pscustomobject]@{ Value = [string]$plan.approval.owner; Description = 'Approval owner' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.previousExecutionGateReference; Description = 'Previous execution gate reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.trafficObservationReference; Description = 'Traffic observation reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.rollbackEvidenceReference; Description = 'Rollback evidence reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.reacceptanceEvidenceReference; Description = 'Reacceptance evidence reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.incidentRecordReference; Description = 'Incident record reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.closureChangeReference; Description = 'Closure change reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.reviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-OperatorValue -Value $value.Value -Description $value.Description
}
if ([string]::Equals(
    [string]$plan.externalEvidence.reviewedBy,
    [string]$plan.approval.owner,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The independent recovery reviewer must be distinct from the incident-closure approval owner.'
}

$generatedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$executedAt = ([DateTimeOffset]$evidence.execution.executedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$observationStartedAt = ([DateTimeOffset]$plan.observation.startedAtUtc).ToUniversalTime()
$observationEndedAt = ([DateTimeOffset]$plan.observation.endedAtUtc).ToUniversalTime()
$observationDuration = $observationEndedAt - $observationStartedAt
$approvalWindow = $expiresAt - $generatedAt
$evidenceAgeAtGeneration = $generatedAt - $collectedAt
$observationAgeAtGeneration = $generatedAt - $observationEndedAt
if (
    [int]$plan.planValidityMinutes -lt 5 -or
    [int]$plan.planValidityMinutes -gt 1440 -or
    [Math]::Abs($approvalWindow.TotalMinutes - [int]$plan.planValidityMinutes) -gt 0.01
) {
    throw 'The recovery incident-closure approval window is invalid.'
}
if (
    [int]$plan.maxFinalExpansionEvidenceAgeMinutes -lt 5 -or
    [int]$plan.maxFinalExpansionEvidenceAgeMinutes -gt 1440 -or
    $evidenceAgeAtGeneration.TotalMinutes -lt -5 -or
    $evidenceAgeAtGeneration.TotalMinutes -gt [int]$plan.maxFinalExpansionEvidenceAgeMinutes -or
    $observationAgeAtGeneration.TotalMinutes -lt -5 -or
    $observationAgeAtGeneration.TotalMinutes -gt [int]$plan.maxFinalExpansionEvidenceAgeMinutes
) {
    throw 'Recovery final expansion execution evidence or the sustained-health observation was stale when the incident-closure plan was generated.'
}
if (
    $observationStartedAt -lt $executedAt -or
    $observationEndedAt -lt $collectedAt -or
    $observationEndedAt -lt $observationStartedAt -or
    [int]$plan.observation.minimumMinutes -lt 5 -or
    [int]$plan.observation.minimumMinutes -gt 1440 -or
    $observationDuration.TotalMinutes -lt [int]$plan.observation.minimumMinutes
) {
    throw 'The incident-closure observation window is incomplete or precedes final expansion execution evidence.'
}
if ([string]$plan.state -eq 'pending' -and $referenceNow -gt $expiresAt) {
    throw 'The pending production recovery incident closure plan has expired.'
}

$hasFailure = (
    [string]$plan.observation.trafficStability -eq 'degraded' -or
    [string]$plan.observation.workloads -eq 'degraded' -or
    [string]$plan.observation.errorBudget -eq 'exhausted' -or
    [string]$plan.observation.alerts -eq 'firing' -or
    [string]$plan.observation.functional -eq 'failed' -or
    [string]$plan.observation.dependencies -eq 'degraded' -or
    [string]$plan.observation.operations -eq 'degraded' -or
    [string]$plan.observation.capacity -eq 'degraded' -or
    [string]$plan.observation.security -eq 'incident' -or
    [string]$plan.observation.drift -eq 'detected' -or
    [string]$plan.observation.certificates -in @('expiring', 'invalid') -or
    [string]$plan.observation.rollbackReadiness -eq 'not-ready' -or
    [string]$plan.observation.reacceptance -eq 'failed' -or
    [string]$plan.observation.incidentRecord -eq 'missing' -or
    [string]$plan.observation.closureChange -eq 'rejected'
)
$hasUnknown = @(
    [string]$plan.observation.trafficStability,
    [string]$plan.observation.workloads,
    [string]$plan.observation.errorBudget,
    [string]$plan.observation.alerts,
    [string]$plan.observation.functional,
    [string]$plan.observation.dependencies,
    [string]$plan.observation.operations,
    [string]$plan.observation.capacity,
    [string]$plan.observation.security,
    [string]$plan.observation.drift,
    [string]$plan.observation.certificates,
    [string]$plan.observation.rollbackReadiness,
    [string]$plan.observation.reacceptance,
    [string]$plan.observation.incidentRecord,
    [string]$plan.observation.closureChange
) -contains 'unknown'
if ([string]$plan.observation.closureChange -eq 'pending') {
    $hasUnknown = $true
}
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedNextAction = switch ($expectedOutcome) {
    'passed' { 'await-independent-recovery-incident-closure-approval' }
    'failed' { 'restore-previous-recovery-boundary-and-escalate' }
    default { 'hold-recovery-boundary-and-collect-evidence' }
}
if (
    [string]$plan.readiness.outcome -ne $expectedOutcome -or
    [string]$plan.decision.nextAction -ne $expectedNextAction -or
    [string]$plan.decision.afterApprovalAction -ne 'close-recovery-incident-externally-after-independent-review' -or
    [int]$plan.decision.holdTrafficAtPercent -ne $currentPercent -or
    [string]$plan.execution.state -ne 'not-started' -or
    [bool]$plan.execution.externalIncidentSystemRequired -ne $true -or
    [bool]$plan.execution.trafficMutationAllowed -ne $false -or
    [bool]$plan.execution.incidentClosurePerformed -ne $false
) {
    throw 'The recovery incident-closure readiness outcome is inconsistent with its observation evidence.'
}

$expectedApprovalStatement = "APPROVE RECOVERY INCIDENT CLOSURE $($plan.closureChangeId) FOR $ExpectedProductionContext INCIDENT $($plan.incidentId) RELEASE $($plan.candidate.version)"
if ([string]$plan.approval.requiredStatement -ne $expectedApprovalStatement) {
    throw 'The production recovery incident-closure approval contract is invalid.'
}

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
    closureChangeId = [string]$plan.closureChangeId
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    planValidityMinutes = [int]$plan.planValidityMinutes
    maxFinalExpansionEvidenceAgeMinutes = [int]$plan.maxFinalExpansionEvidenceAgeMinutes
    releaseVersion = [string]$evidence.candidate.version
    sourceTag = [string]$evidence.candidate.sourceTag
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    trafficController = [string]$evidence.traffic.controller
    currentTrafficPercent = $currentPercent
    holdTrafficPercent = $holdPercent
    requiredHoldPercent = 100
    trafficMutationPercentagePoints = 0
    observationStartedAtUtc = $observationStartedAt.ToString('o')
    observationEndedAtUtc = $observationEndedAt.ToString('o')
    observationMinutes = [int]$plan.observation.minimumMinutes
    observedTrafficPercent = [int]$plan.observation.observedTrafficPercent
    trafficStabilityStatus = [string]$plan.observation.trafficStability
    workloadStatus = [string]$plan.observation.workloads
    errorBudgetStatus = [string]$plan.observation.errorBudget
    alertStatus = [string]$plan.observation.alerts
    functionalStatus = [string]$plan.observation.functional
    dependencyStatus = [string]$plan.observation.dependencies
    operationalStatus = [string]$plan.observation.operations
    capacityStatus = [string]$plan.observation.capacity
    securityStatus = [string]$plan.observation.security
    driftStatus = [string]$plan.observation.drift
    certificateStatus = [string]$plan.observation.certificates
    rollbackReadinessStatus = [string]$plan.observation.rollbackReadiness
    reacceptanceStatus = [string]$plan.observation.reacceptance
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    incidentRecordStatus = [string]$plan.observation.incidentRecord
    closureChangeStatus = [string]$plan.observation.closureChange
    previousExecutionGateReference = [string]$plan.externalEvidence.previousExecutionGateReference
    trafficObservationReference = [string]$plan.externalEvidence.trafficObservationReference
    monitoringEvidenceReference = [string]$plan.externalEvidence.monitoringEvidenceReference
    rollbackEvidenceReference = [string]$plan.externalEvidence.rollbackEvidenceReference
    reacceptanceEvidenceReference = [string]$plan.externalEvidence.reacceptanceEvidenceReference
    incidentRecordReference = [string]$plan.externalEvidence.incidentRecordReference
    closureChangeReference = [string]$plan.externalEvidence.closureChangeReference
    approvalOwner = [string]$plan.approval.owner
    reviewedBy = [string]$plan.externalEvidence.reviewedBy
    readinessOutcome = $expectedOutcome
    nextAction = $expectedNextAction
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production recovery incident closure plan integrity digest is invalid.'
}

$requiredSafeguards = @(
    'passed-immutable-recovery-final-expansion-execution-evidence',
    'completed-sustained-one-hundred-percent-observation',
    'passed-independent-production-reacceptance',
    'healthy-error-budget-and-operational-signals',
    'separate-recovery-incident-closure-change-record',
    'separate-exact-incident-closure-approval',
    'hold-one-hundred-percent-with-zero-traffic-mutation',
    'exactly-one-hundred-percent-traffic',
    'external-traffic-enforcement',
    'rollback-to-previous-recovery-boundary',
    'emergency-disable-to-zero',
    'no-automatic-production-mutation',
    'preserve-incident-audit-evidence'
)
foreach ($safeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $safeguard) {
        throw "The recovery incident closure plan is missing safeguard '$safeguard'."
    }
}

if ($expectedOutcome -eq 'passed' -and [string]$plan.state -notin @('pending', 'approved')) {
    throw 'A passed recovery incident closure plan must be pending or approved.'
}
if ($expectedOutcome -ne 'passed' -and [string]$plan.state -ne 'blocked') {
    throw 'Failed or unknown recovery incident-closure evidence must remain blocked.'
}
if ([string]$plan.state -eq 'blocked') {
    if (
        [string]$plan.approval.status -ne 'blocked' -or
        $null -ne $plan.approval.approvedBy -or
        $null -ne $plan.approval.approvedAtUtc -or
        $null -ne $plan.approval.approvedAtUnixSeconds -or
        $null -ne $plan.approval.approvalStatement -or
        $null -ne $plan.approval.approvalDigest
    ) {
        throw 'The blocked recovery incident closure plan contains approval data.'
    }
}
elseif ([string]$plan.state -eq 'pending') {
    if (
        [string]$plan.approval.status -ne 'pending' -or
        $null -ne $plan.approval.approvedBy -or
        $null -ne $plan.approval.approvedAtUtc -or
        $null -ne $plan.approval.approvedAtUnixSeconds -or
        $null -ne $plan.approval.approvalStatement -or
        $null -ne $plan.approval.approvalDigest
    ) {
        throw 'The pending recovery incident closure plan contains approval data.'
    }
}
elseif ([string]$plan.state -eq 'approved') {
    if (
        $expectedOutcome -ne 'passed' -or
        [string]$plan.approval.status -ne 'approved' -or
        [string]::IsNullOrWhiteSpace([string]$plan.approval.approvedBy) -or
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $expectedApprovalStatement
    ) {
        throw 'The approved recovery incident closure plan has invalid approval data.'
    }
    $approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if (
        $approvedAt.ToUnixTimeSeconds() -ne $approvedAtUnixSeconds -or
        $approvedAt -lt $generatedAt -or
        $approvedAt -gt $expiresAt
    ) {
        throw 'The recovery incident-closure approval timestamp is invalid or outside the approval window.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The recovery incident-closure approval digest is invalid.'
    }
}
else {
    throw "Unsupported production recovery incident-closure state '$($plan.state)'."
}

if ($RequiredState -ne 'Any' -and [string]$plan.state -ne $RequiredState.ToLowerInvariant()) {
    throw "Recovery incident closure plan state is '$($plan.state)'; expected '$($RequiredState.ToLowerInvariant())'."
}

Write-Host "Production recovery incident closure plan validation passed for incident $($plan.incidentId)."
Write-Host "Recovery boundary held at $holdPercent%; incident-closure readiness: $expectedOutcome"
Write-Host 'This validator is read-only and does not change traffic or close the incident.'
