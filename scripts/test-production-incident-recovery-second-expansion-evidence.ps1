[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

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

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production incident recovery second expansion evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'incident-recovery-second-expansion-execution'
) {
    throw 'The supplied production incident recovery second expansion evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The recovery second expansion evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The recovery second expansion evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPlanPath = if ([string]::IsNullOrWhiteSpace($SecondExpansionPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.secondExpansionPlan.relativePath) -Description 'Recorded second expansion plan path'
}
else {
    Resolve-LocalStatePath -Path $SecondExpansionPlanPath -Description 'SecondExpansionPlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Recorded production incident recovery second expansion plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ProgressiveEvidencePath'; Value = $ProgressiveEvidencePath }
    [pscustomobject]@{ Name = 'ProgressivePlanPath'; Value = $ProgressivePlanPath }
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
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-second-expansion-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $planRelativePath -ne [string]$evidence.secondExpansionPlan.relativePath -or
    $planHash -ne [string]$evidence.secondExpansionPlan.sha256 -or
    [string]$plan.integrityDigest -ne [string]$evidence.secondExpansionPlan.integrityDigest -or
    [string]$plan.approval.approvalDigest -ne [string]$evidence.secondExpansionPlan.approvalDigest -or
    [string]$evidence.secondExpansionPlan.state -ne 'approved' -or
    ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.secondExpansionPlan.approvedAtUtc).ToUniversalTime().ToString('o') -or
    ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.secondExpansionPlan.expiresAtUtc).ToUniversalTime().ToString('o')
) {
    throw 'The approved production recovery second expansion plan no longer matches execution evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$plan.incidentId -or
    [string]$evidence.containmentChangeId -ne [string]$plan.containmentChangeId -or
    [string]$evidence.recoveryChangeId -ne [string]$plan.recoveryChangeId -or
    [string]$evidence.expansionChangeId -ne [string]$plan.expansionChangeId -or
    [string]$evidence.progressiveChangeId -ne [string]$plan.progressiveChangeId -or
    [string]$evidence.secondExpansionChangeId -ne [string]$plan.secondExpansionChangeId
) {
    throw 'The recovery second expansion execution identity does not match the approved plan.'
}
if (
    [string]$evidence.candidate.version -ne [string]$plan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$plan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$plan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$plan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$plan.candidate.policyVersion
) {
    throw 'The recovery second expansion execution candidate does not match the approved plan.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'traffic enforcement'; Actual = [string]$evidence.traffic.enforcementStatus; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'workload verification'; Actual = [string]$evidence.verification.workloads; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'second expansion execution'; Actual = [string]$evidence.execution.status; Allowed = @('completed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$evidence.verification.errorBudget; Allowed = @('within-budget', 'exhausted', 'unknown') }
    [pscustomobject]@{ Name = 'alerts'; Actual = [string]$evidence.verification.alerts; Allowed = @('clear', 'firing', 'unknown') }
    [pscustomobject]@{ Name = 'functional'; Actual = [string]$evidence.verification.functional; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$evidence.verification.dependencies; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$evidence.verification.operations; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'capacity'; Actual = [string]$evidence.verification.capacity; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'security'; Actual = [string]$evidence.verification.security; Allowed = @('clear', 'incident', 'unknown') }
    [pscustomobject]@{ Name = 'drift'; Actual = [string]$evidence.verification.drift; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'certificates'; Actual = [string]$evidence.verification.certificates; Allowed = @('healthy', 'expiring', 'invalid', 'unknown') }
    [pscustomobject]@{ Name = 'rollback readiness'; Actual = [string]$evidence.verification.rollbackReadiness; Allowed = @('ready', 'not-ready', 'unknown') }
    [pscustomobject]@{ Name = 'incident record'; Actual = [string]$evidence.verification.incidentRecord; Allowed = @('updated', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'second expansion change record'; Actual = [string]$evidence.verification.secondExpansionChangeRecord; Allowed = @('updated', 'missing', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The recovery second expansion evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.workloadEvidenceReference; Description = 'Workload evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.secondExpansionExecutionReference; Description = 'Second expansion execution reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.secondExpansionGateReference; Description = 'Second expansion gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.monitoringEvidenceReference; Description = 'Monitoring evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackEvidenceReference; Description = 'Rollback evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.incidentRecordReference; Description = 'Incident record reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.secondExpansionChangeRecordReference; Description = 'Second expansion change record reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.collectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$expectedTrafficPercent = [int]$plan.traffic.targetPercent
$trafficMatchesPlan = [int]$evidence.traffic.observedPercent -eq $expectedTrafficPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [string]$evidence.traffic.controller -ne [string]$plan.traffic.controller -or
    [int]$evidence.traffic.previousBoundaryPercent -ne [int]$plan.traffic.currentPercent -or
    [int]$evidence.traffic.expectedPercent -ne $expectedTrafficPercent -or
    [bool]$evidence.traffic.matchesPlan -ne $trafficMatchesPlan -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced
) {
    throw 'The recovery second expansion traffic boundary is inconsistent with the approved plan.'
}
if (
    [string]$evidence.rollback.mode -ne [string]$plan.rollback.mode -or
    [int]$evidence.rollback.targetPercent -ne [int]$plan.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$plan.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$plan.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$plan.rollback.procedureReference -or
    [string]$evidence.rollback.readinessStatus -ne [string]$evidence.verification.rollbackReadiness
) {
    throw 'The recovery second expansion rollback evidence is inconsistent with the approved plan.'
}

$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$executedAt = ([DateTimeOffset]$evidence.execution.executedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$executionAgeAtCollection = $collectedAt - $executedAt
if (
    $executedAt -lt $approvedAt -or
    $executedAt -gt $expiresAt -or
    $executionAgeAtCollection.TotalMinutes -lt -5 -or
    [int]$evidence.maxExecutionAgeMinutes -lt 5 -or
    [int]$evidence.maxExecutionAgeMinutes -gt 1440 -or
    $executionAgeAtCollection.TotalMinutes -gt [int]$evidence.maxExecutionAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The recovery second expansion execution or collection timestamp is invalid.'
}

$hasFailure = (
    [string]$evidence.traffic.enforcementStatus -eq 'failed' -or
    [string]$evidence.verification.workloads -eq 'failed' -or
    [string]$evidence.execution.status -eq 'failed' -or
    [string]$evidence.verification.errorBudget -eq 'exhausted' -or
    [string]$evidence.verification.alerts -eq 'firing' -or
    [string]$evidence.verification.functional -eq 'failed' -or
    [string]$evidence.verification.dependencies -eq 'degraded' -or
    [string]$evidence.verification.operations -eq 'degraded' -or
    [string]$evidence.verification.capacity -eq 'degraded' -or
    [string]$evidence.verification.security -eq 'incident' -or
    [string]$evidence.verification.drift -eq 'detected' -or
    [string]$evidence.verification.certificates -in @('expiring', 'invalid') -or
    [string]$evidence.verification.rollbackReadiness -eq 'not-ready' -or
    [string]$evidence.verification.incidentRecord -eq 'missing' -or
    [string]$evidence.verification.secondExpansionChangeRecord -eq 'missing' -or
    -not $trafficMatchesPlan
)
$hasUnknown = @(
    [string]$evidence.traffic.enforcementStatus,
    [string]$evidence.verification.workloads,
    [string]$evidence.execution.status,
    [string]$evidence.verification.errorBudget,
    [string]$evidence.verification.alerts,
    [string]$evidence.verification.functional,
    [string]$evidence.verification.dependencies,
    [string]$evidence.verification.operations,
    [string]$evidence.verification.capacity,
    [string]$evidence.verification.security,
    [string]$evidence.verification.drift,
    [string]$evidence.verification.certificates,
    [string]$evidence.verification.rollbackReadiness,
    [string]$evidence.verification.incidentRecord,
    [string]$evidence.verification.secondExpansionChangeRecord
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedTargetReached = $expectedOutcome -eq 'passed'
$expectedNextAction = switch ($expectedOutcome) {
    'passed' { 'observe-recovery-second-expansion-before-next-step' }
    'failed' { 'restore-previous-recovery-boundary-and-escalate' }
    default { 'hold-safest-recovery-boundary-and-collect-evidence' }
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.decision.targetReached -ne $expectedTargetReached -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The recovery second expansion outcome is inconsistent with recorded verification states.'
}

$integrity = [ordered]@{
    secondExpansionPlanSha256 = $planHash
    secondExpansionPlanIntegrityDigest = [string]$plan.integrityDigest
    secondExpansionPlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    secondExpansionChangeId = [string]$plan.secondExpansionChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    trafficController = [string]$plan.traffic.controller
    previousBoundaryPercent = [int]$plan.traffic.currentPercent
    expectedTrafficPercent = $expectedTrafficPercent
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = [string]$evidence.traffic.enforcementStatus
    workloadVerificationStatus = [string]$evidence.verification.workloads
    secondExpansionExecutionStatus = [string]$evidence.execution.status
    errorBudgetStatus = [string]$evidence.verification.errorBudget
    alertStatus = [string]$evidence.verification.alerts
    functionalStatus = [string]$evidence.verification.functional
    dependencyStatus = [string]$evidence.verification.dependencies
    operationalStatus = [string]$evidence.verification.operations
    capacityStatus = [string]$evidence.verification.capacity
    securityStatus = [string]$evidence.verification.security
    driftStatus = [string]$evidence.verification.drift
    certificateStatus = [string]$evidence.verification.certificates
    rollbackReadinessStatus = [string]$evidence.verification.rollbackReadiness
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    incidentRecordStatus = [string]$evidence.verification.incidentRecord
    secondExpansionChangeRecordStatus = [string]$evidence.verification.secondExpansionChangeRecord
    executedAtUtc = $executedAt.ToString('o')
    maxExecutionAgeMinutes = [int]$evidence.maxExecutionAgeMinutes
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    workloadEvidenceReference = [string]$evidence.externalEvidence.workloadEvidenceReference
    secondExpansionExecutionReference = [string]$evidence.externalEvidence.secondExpansionExecutionReference
    secondExpansionGateReference = [string]$evidence.externalEvidence.secondExpansionGateReference
    monitoringEvidenceReference = [string]$evidence.externalEvidence.monitoringEvidenceReference
    rollbackEvidenceReference = [string]$evidence.externalEvidence.rollbackEvidenceReference
    incidentRecordReference = [string]$evidence.externalEvidence.incidentRecordReference
    secondExpansionChangeRecordReference = [string]$evidence.externalEvidence.secondExpansionChangeRecordReference
    collectedBy = [string]$evidence.externalEvidence.collectedBy
    targetReached = $expectedTargetReached
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production recovery second expansion evidence integrity digest is invalid.'
}

Write-Host "Production recovery second expansion evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Verified recovery second expansion boundary: $($evidence.traffic.observedPercent)%; next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not authorize further expansion or close the incident.'
