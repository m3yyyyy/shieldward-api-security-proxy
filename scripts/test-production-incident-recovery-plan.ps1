[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery/recovery.json',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateSet('Any', 'Pending', 'Approved', 'Blocked')]
    [string]$RequiredState = 'Any',

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

function Assert-OperatorValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Description,
        [int]$MaximumLength = 256
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most $MaximumLength characters without control characters."
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

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'production-incident-recovery'
) {
    throw 'The supplied production incident recovery plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The recovery plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The recovery plan uses unsupported namespace '$($plan.namespace)'."
}
foreach ($identifier in @(
    [pscustomobject]@{ Value = [string]$plan.incidentId; Description = 'IncidentId' }
    [pscustomobject]@{ Value = [string]$plan.containmentChangeId; Description = 'ContainmentChangeId' }
    [pscustomobject]@{ Value = [string]$plan.recoveryChangeId; Description = 'RecoveryChangeId' }
)) {
    if ($identifier.Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$') {
        throw "The recovery plan has an invalid $($identifier.Description)."
    }
    Assert-OperatorValue -Value $identifier.Value -Description $identifier.Description -MaximumLength 128
}
if ([string]::Equals([string]$plan.containmentChangeId, [string]$plan.recoveryChangeId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The recovery change must be separate from the containment change.'
}
Assert-OperatorValue -Value ([string]$plan.recovery.owner) -Description 'Recovery owner' -MaximumLength 128

$resolvedContainmentPath = if ([string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.containmentEvidence.relativePath) -Description 'Recorded containment evidence path'
}
else {
    Resolve-LocalStatePath -Path $ContainmentEvidencePath -Description 'ContainmentEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedContainmentPath -PathType Leaf)) {
    throw "Recorded production incident containment evidence is missing: $resolvedContainmentPath"
}
$containmentValidationArguments = @{
    EvidencePath = $resolvedContainmentPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $containmentValidationArguments.PlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') @containmentValidationArguments 6>$null

$containment = Get-Content -Raw -LiteralPath $resolvedContainmentPath | ConvertFrom-Json
$containmentRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedContainmentPath).Replace('\', '/')
$containmentHash = (Get-FileHash -LiteralPath $resolvedContainmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $containmentRelativePath -ne [string]$plan.containmentEvidence.relativePath -or
    $containmentHash -ne [string]$plan.containmentEvidence.sha256 -or
    [string]$containment.integrityDigest -ne [string]$plan.containmentEvidence.integrityDigest -or
    [string]$containment.outcome -ne [string]$plan.containmentEvidence.outcome -or
    ([DateTimeOffset]$containment.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$plan.containmentEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [string]$containment.responsePlan.sha256 -ne [string]$plan.containmentEvidence.responsePlanSha256 -or
    [string]$containment.responsePlan.integrityDigest -ne [string]$plan.containmentEvidence.responsePlanIntegrityDigest -or
    [string]$containment.responsePlan.approvalDigest -ne [string]$plan.containmentEvidence.responsePlanApprovalDigest
) {
    throw 'The containment evidence no longer matches the incident recovery plan.'
}
if (
    [string]$containment.outcome -ne 'passed' -or
    [bool]$containment.response.deadlineMet -ne $true -or
    [string]$containment.response.executionStatus -ne 'completed' -or
    [bool]$containment.traffic.matchesPlan -ne $true -or
    [string]$containment.traffic.enforcementStatus -ne 'confirmed' -or
    [string]$containment.verification.workloads -ne 'confirmed' -or
    [string]$containment.verification.incidentRecord -ne 'updated'
) {
    throw 'Incident recovery planning requires passed containment evidence at the exact approved boundary.'
}
if (
    [string]$plan.incidentId -ne [string]$containment.incidentId -or
    [string]$plan.containmentChangeId -ne [string]$containment.changeId
) {
    throw 'The recovery incident identity does not match containment evidence.'
}
if (
    [string]$plan.candidate.version -ne [string]$containment.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$containment.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$containment.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$containment.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$containment.candidate.policyVersion
) {
    throw 'The recovery candidate no longer matches containment evidence.'
}

$currentTrafficPercent = [int]$containment.traffic.observedPercent
$targetTrafficPercent = [int]$plan.traffic.targetPercent
$expectedRecoveryMode = switch ($currentTrafficPercent) {
    0 {
        if ($targetTrafficPercent -lt 1 -or $targetTrafficPercent -gt 10) {
            throw 'Recovery from zero traffic must use an externally enforced canary of 1-10 percent.'
        }
        'bounded-canary-restoration'
    }
    75 {
        if ($targetTrafficPercent -ne 100) {
            throw 'Recovery from the 75 percent containment cohort must target exactly 100 percent.'
        }
        'restore-full-traffic'
    }
    100 {
        if ($targetTrafficPercent -ne 100) {
            throw 'Recovery from a 100 percent hold must remain exactly at 100 percent.'
        }
        'resume-at-current-boundary'
    }
    default {
        throw "Unsupported containment boundary '$currentTrafficPercent%'."
    }
}
if (
    [string]$plan.traffic.controller -ne [string]$containment.traffic.controller -or
    [int]$plan.traffic.currentPercent -ne $currentTrafficPercent -or
    [bool]$plan.traffic.externallyConfirmed -ne ([string]$plan.traffic.currentStatus -eq 'confirmed') -or
    [bool]$plan.traffic.externalExecutionRequired -ne $true -or
    [string]$plan.recovery.mode -ne $expectedRecoveryMode
) {
    throw 'The recovery traffic boundary is inconsistent with containment evidence.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'current traffic'; Actual = [string]$plan.traffic.currentStatus; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'remediation'; Actual = [string]$plan.readiness.remediationStatus; Allowed = @('completed', 'not-required', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 're-acceptance'; Actual = [string]$plan.readiness.reacceptanceStatus; Allowed = @('passed', 'not-required', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'functional'; Actual = [string]$plan.readiness.functionalStatus; Allowed = @('passed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'dependencies'; Actual = [string]$plan.readiness.dependencyStatus; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'operations'; Actual = [string]$plan.readiness.operationalStatus; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'capacity'; Actual = [string]$plan.readiness.capacityStatus; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'security'; Actual = [string]$plan.readiness.securityStatus; Allowed = @('clear', 'incident', 'unknown') }
    [pscustomobject]@{ Name = 'drift'; Actual = [string]$plan.readiness.driftStatus; Allowed = @('clear', 'detected', 'unknown') }
    [pscustomobject]@{ Name = 'certificates'; Actual = [string]$plan.readiness.certificateStatus; Allowed = @('healthy', 'expiring', 'invalid', 'unknown') }
    [pscustomobject]@{ Name = 'incident record'; Actual = [string]$plan.readiness.incidentRecordStatus; Allowed = @('updated', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'recovery change'; Actual = [string]$plan.readiness.recoveryChangeStatus; Allowed = @('approved', 'pending', 'missing', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The recovery plan contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.remediationEvidenceReference; Description = 'Remediation evidence reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.reacceptanceEvidenceReference; Description = 'Re-acceptance evidence reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.recoveryVerificationReference; Description = 'Recovery verification reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.incidentRecordReference; Description = 'Incident record reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.recoveryChangeReference; Description = 'Recovery change reference' }
    [pscustomobject]@{ Value = [string]$plan.externalEvidence.reviewedBy; Description = 'Recovery reviewer' }
)) {
    Assert-OperatorValue -Value $reference.Value -Description $reference.Description
}

$remediationRequired = [string]$containment.decision.nextAction -in @(
    'remediate-before-restoration',
    'remediate-and-prepare-recovery'
)
$reacceptanceRequired = [bool]$containment.decision.reacceptanceRequired
$hasFailure = (
    [string]$plan.traffic.currentStatus -eq 'failed' -or
    [string]$plan.readiness.remediationStatus -eq 'failed' -or
    [string]$plan.readiness.reacceptanceStatus -eq 'failed' -or
    [string]$plan.readiness.functionalStatus -eq 'failed' -or
    [string]$plan.readiness.dependencyStatus -eq 'degraded' -or
    [string]$plan.readiness.operationalStatus -eq 'degraded' -or
    [string]$plan.readiness.capacityStatus -eq 'degraded' -or
    [string]$plan.readiness.securityStatus -eq 'incident' -or
    [string]$plan.readiness.driftStatus -eq 'detected' -or
    [string]$plan.readiness.certificateStatus -in @('expiring', 'invalid') -or
    [string]$plan.readiness.incidentRecordStatus -eq 'missing' -or
    [string]$plan.readiness.recoveryChangeStatus -eq 'missing' -or
    ($remediationRequired -and [string]$plan.readiness.remediationStatus -eq 'not-required') -or
    ($reacceptanceRequired -and [string]$plan.readiness.reacceptanceStatus -eq 'not-required')
)
$hasUnknown = @(
    [string]$plan.traffic.currentStatus,
    [string]$plan.readiness.remediationStatus,
    [string]$plan.readiness.reacceptanceStatus,
    [string]$plan.readiness.functionalStatus,
    [string]$plan.readiness.dependencyStatus,
    [string]$plan.readiness.operationalStatus,
    [string]$plan.readiness.capacityStatus,
    [string]$plan.readiness.securityStatus,
    [string]$plan.readiness.driftStatus,
    [string]$plan.readiness.certificateStatus,
    [string]$plan.readiness.incidentRecordStatus,
    [string]$plan.readiness.recoveryChangeStatus
) -contains 'unknown'
if ([string]$plan.readiness.recoveryChangeStatus -eq 'pending') {
    $hasUnknown = $true
}
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedNextAction = switch ($expectedOutcome) {
    'passed' { 'await-explicit-recovery-approval' }
    'failed' { 'continue-remediation-and-hold-traffic' }
    default { 'collect-current-recovery-evidence-and-hold-traffic' }
}
if (
    [bool]$plan.readiness.remediationRequired -ne $remediationRequired -or
    [bool]$plan.readiness.reacceptanceRequired -ne $reacceptanceRequired -or
    [string]$plan.readiness.outcome -ne $expectedOutcome -or
    [string]$plan.decision.nextAction -ne $expectedNextAction -or
    [string]$plan.decision.afterApprovalAction -ne 'execute-approved-recovery-externally' -or
    [int]$plan.decision.holdTrafficAtPercent -ne $currentTrafficPercent
) {
    throw 'The recovery readiness outcome is inconsistent with its recorded verification states.'
}
if (
    [string]$plan.recovery.owner -ne [string]$containment.response.authority -or
    [string]$plan.recovery.procedureReference -ne [string]$containment.response.procedureReference -or
    [string]$plan.recovery.executionState -ne 'not-started' -or
    [bool]$plan.recovery.externalIncidentSystemRequired -ne $true -or
    [bool]$plan.recovery.externalTrafficControllerRequired -ne $true -or
    [int]$plan.rollback.targetPercent -ne $currentTrafficPercent -or
    [int]$plan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$plan.rollback.authority -ne [string]$plan.recovery.owner -or
    [string]$plan.rollback.procedureReference -ne [string]$containment.response.procedureReference
) {
    throw 'The recovery execution or rollback boundary is invalid.'
}

$generatedAt = [DateTimeOffset]$plan.generatedAtUtc
$expiresAt = [DateTimeOffset]$plan.expiresAtUtc
$containmentCollectedAt = [DateTimeOffset]$containment.collectedAtUtc
$approvalWindow = $expiresAt.ToUniversalTime() - $generatedAt.ToUniversalTime()
$containmentAgeAtGeneration = $generatedAt.ToUniversalTime() - $containmentCollectedAt.ToUniversalTime()
if (
    [int]$plan.approvalWindowMinutes -lt 5 -or
    [int]$plan.approvalWindowMinutes -gt 1440 -or
    [Math]::Abs($approvalWindow.TotalMinutes - [int]$plan.approvalWindowMinutes) -gt 0.01
) {
    throw 'The recovery approval window is invalid.'
}
if (
    [int]$plan.maxContainmentAgeMinutes -lt 5 -or
    [int]$plan.maxContainmentAgeMinutes -gt 43200 -or
    $containmentAgeAtGeneration.TotalMinutes -lt -5 -or
    $containmentAgeAtGeneration.TotalMinutes -gt [int]$plan.maxContainmentAgeMinutes
) {
    throw 'Containment evidence was outside the recorded recovery age when the plan was generated.'
}
if ([string]$plan.state -eq 'pending' -and [DateTimeOffset]::UtcNow -gt $expiresAt.ToUniversalTime()) {
    throw 'The pending production incident recovery plan has expired.'
}

$expectedApprovalStatement = "APPROVE PRODUCTION INCIDENT RECOVERY $($plan.incidentId) $($plan.recoveryChangeId) FOR $ExpectedProductionContext FROM $currentTrafficPercent% TO $targetTrafficPercent%"
if (
    [string]$plan.approval.owner -ne [string]$plan.recovery.owner -or
    [string]$plan.approval.requiredStatement -ne $expectedApprovalStatement
) {
    throw 'The production incident recovery approval contract is invalid.'
}

$integrity = [ordered]@{
    containmentEvidenceSha256 = $containmentHash
    containmentEvidenceIntegrityDigest = [string]$containment.integrityDigest
    responsePlanSha256 = [string]$containment.responsePlan.sha256
    responsePlanIntegrityDigest = [string]$containment.responsePlan.integrityDigest
    responsePlanApprovalDigest = [string]$containment.responsePlan.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$containment.incidentId
    containmentChangeId = [string]$containment.changeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    generatedAtUtc = $generatedAt.ToUniversalTime().ToString('o')
    expiresAtUtc = $expiresAt.ToUniversalTime().ToString('o')
    approvalWindowMinutes = [int]$plan.approvalWindowMinutes
    maxContainmentAgeMinutes = [int]$plan.maxContainmentAgeMinutes
    releaseVersion = [string]$containment.candidate.version
    sourceTag = [string]$containment.candidate.sourceTag
    controlPlaneImage = [string]$containment.candidate.controlPlaneImage
    edgeImage = [string]$containment.candidate.edgeImage
    policyVersion = [string]$containment.candidate.policyVersion
    trafficController = [string]$containment.traffic.controller
    currentTrafficPercent = $currentTrafficPercent
    targetTrafficPercent = $targetTrafficPercent
    currentTrafficStatus = [string]$plan.traffic.currentStatus
    recoveryMode = $expectedRecoveryMode
    remediationRequired = $remediationRequired
    remediationStatus = [string]$plan.readiness.remediationStatus
    reacceptanceRequired = $reacceptanceRequired
    reacceptanceStatus = [string]$plan.readiness.reacceptanceStatus
    functionalStatus = [string]$plan.readiness.functionalStatus
    dependencyStatus = [string]$plan.readiness.dependencyStatus
    operationalStatus = [string]$plan.readiness.operationalStatus
    capacityStatus = [string]$plan.readiness.capacityStatus
    securityStatus = [string]$plan.readiness.securityStatus
    driftStatus = [string]$plan.readiness.driftStatus
    certificateStatus = [string]$plan.readiness.certificateStatus
    incidentRecordStatus = [string]$plan.readiness.incidentRecordStatus
    recoveryChangeStatus = [string]$plan.readiness.recoveryChangeStatus
    trafficStateReference = [string]$plan.externalEvidence.trafficStateReference
    remediationEvidenceReference = [string]$plan.externalEvidence.remediationEvidenceReference
    reacceptanceEvidenceReference = [string]$plan.externalEvidence.reacceptanceEvidenceReference
    recoveryVerificationReference = [string]$plan.externalEvidence.recoveryVerificationReference
    incidentRecordReference = [string]$plan.externalEvidence.incidentRecordReference
    recoveryChangeReference = [string]$plan.externalEvidence.recoveryChangeReference
    recoveryOwner = [string]$plan.recovery.owner
    reviewedBy = [string]$plan.externalEvidence.reviewedBy
    readinessOutcome = $expectedOutcome
    nextAction = $expectedNextAction
    afterApprovalAction = 'execute-approved-recovery-externally'
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production incident recovery plan integrity digest is invalid.'
}

$requiredSafeguards = @(
    'passed-immutable-containment-evidence',
    'separate-recovery-change-record',
    'current-contained-traffic-confirmation',
    'explicit-remediation-and-reacceptance-status',
    'healthy-recovery-verification',
    'bounded-zero-to-canary-restoration',
    'exact-seventy-five-to-full-restoration',
    'explicit-recovery-approval',
    'restore-only-through-external-controller',
    'rollback-to-contained-boundary',
    'no-automatic-production-mutation',
    'preserve-audit-evidence'
)
foreach ($safeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $safeguard) {
        throw "The recovery plan is missing safeguard '$safeguard'."
    }
}

if ($expectedOutcome -eq 'passed' -and [string]$plan.state -notin @('pending', 'approved')) {
    throw 'A passed recovery plan must be pending or approved.'
}
if ($expectedOutcome -ne 'passed' -and [string]$plan.state -ne 'blocked') {
    throw 'Failed or unknown recovery readiness must remain blocked.'
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
        throw 'The blocked recovery plan contains approval data.'
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
        throw 'The pending recovery plan contains approval data.'
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
        throw 'The approved recovery plan has invalid approval data.'
    }
    $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if (
        $approvedAt.ToUnixTimeSeconds() -ne $approvedAtUnixSeconds -or
        $approvedAt.ToUniversalTime() -lt $generatedAt.ToUniversalTime() -or
        $approvedAt.ToUniversalTime() -gt $expiresAt.ToUniversalTime()
    ) {
        throw 'The recovery approval timestamp is invalid or outside the approval window.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The recovery approval digest is invalid.'
    }
}
else {
    throw "Unsupported production incident recovery state '$($plan.state)'."
}

if ($RequiredState -ne 'Any' -and [string]$plan.state -ne $RequiredState.ToLowerInvariant()) {
    throw "Recovery plan state is '$($plan.state)'; expected '$($RequiredState.ToLowerInvariant())'."
}

Write-Host "Production incident recovery plan validation passed for incident $($plan.incidentId)."
Write-Host "Recovery boundary: $currentTrafficPercent% to $targetTrafficPercent%; readiness: $expectedOutcome"
Write-Host 'This validator is read-only and does not change or prove restored production traffic.'
