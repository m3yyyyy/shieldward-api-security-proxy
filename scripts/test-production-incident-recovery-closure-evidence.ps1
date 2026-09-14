[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$ClosurePlanPath = '',
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
    throw "Production incident recovery closure evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'incident-recovery-closure-execution'
) {
    throw 'The supplied production incident recovery closure evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The recovery closure evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The recovery closure evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPlanPath = if ([string]::IsNullOrWhiteSpace($ClosurePlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.closurePlan.relativePath) -Description 'Recorded closure plan path'
}
else {
    Resolve-LocalStatePath -Path $ClosurePlanPath -Description 'ClosurePlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Recorded production incident recovery closure plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'FinalExpansionEvidencePath'; Value = $FinalExpansionEvidencePath }
    [pscustomobject]@{ Name = 'FinalExpansionPlanPath'; Value = $FinalExpansionPlanPath }
    [pscustomobject]@{ Name = 'SecondExpansionEvidencePath'; Value = $SecondExpansionEvidencePath }
    [pscustomobject]@{ Name = 'SecondExpansionPlanPath'; Value = $SecondExpansionPlanPath }
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
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $planRelativePath -ne [string]$evidence.closurePlan.relativePath -or
    $planHash -ne [string]$evidence.closurePlan.sha256 -or
    [string]$plan.integrityDigest -ne [string]$evidence.closurePlan.integrityDigest -or
    [string]$plan.approval.approvalDigest -ne [string]$evidence.closurePlan.approvalDigest -or
    [string]$evidence.closurePlan.state -ne 'approved' -or
    ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.closurePlan.approvedAtUtc).ToUniversalTime().ToString('o') -or
    ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.closurePlan.expiresAtUtc).ToUniversalTime().ToString('o')
) {
    throw 'The approved production recovery closure plan no longer matches closure execution evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$plan.incidentId -or
    [string]$evidence.containmentChangeId -ne [string]$plan.containmentChangeId -or
    [string]$evidence.recoveryChangeId -ne [string]$plan.recoveryChangeId -or
    [string]$evidence.expansionChangeId -ne [string]$plan.expansionChangeId -or
    [string]$evidence.progressiveChangeId -ne [string]$plan.progressiveChangeId -or
    [string]$evidence.finalExpansionChangeId -ne [string]$plan.finalExpansionChangeId -or
    [string]$evidence.closureChangeId -ne [string]$plan.closureChangeId
) {
    throw 'The recovery closure execution identity does not match the approved plan.'
}
if (
    [string]$evidence.candidate.version -ne [string]$plan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$plan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$plan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$plan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$plan.candidate.policyVersion
) {
    throw 'The recovery closure execution candidate does not match the approved plan.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'traffic enforcement'; Actual = [string]$evidence.traffic.enforcementStatus; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'closure execution'; Actual = [string]$evidence.execution.status; Allowed = @('completed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'incident closure'; Actual = [string]$evidence.closure.incidentStatus; Allowed = @('closed', 'open', 'unknown') }
    [pscustomobject]@{ Name = 'closure change record'; Actual = [string]$evidence.closure.changeRecordStatus; Allowed = @('completed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'post-closure monitoring'; Actual = [string]$evidence.verification.postClosureMonitoring; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'rollback retention'; Actual = [string]$evidence.verification.rollbackRetention; Allowed = @('retained', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'audit evidence'; Actual = [string]$evidence.verification.auditEvidence; Allowed = @('complete', 'incomplete', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The recovery closure evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.closureGateReference; Description = 'Closure gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.incidentClosureReference; Description = 'Incident closure reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.closureChangeRecordReference; Description = 'Closure change record reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.postClosureMonitoringReference; Description = 'Post-closure monitoring reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackRetentionReference; Description = 'Rollback retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.auditEvidenceReference; Description = 'Audit evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.collectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

if (
    [int]$plan.traffic.currentPercent -ne 100 -or
    [int]$plan.traffic.holdPercent -ne 100 -or
    [int]$plan.traffic.trafficMutationPercentagePoints -ne 0 -or
    [int]$plan.rollback.targetPercent -ne 75 -or
    [int]$plan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$plan.observation.reacceptance -ne 'passed'
) {
    throw 'Recovery closure evidence requires the approved 100-percent hold, zero-mutation, re-acceptance, and rollback contract.'
}
$trafficMatchesPlan = [int]$evidence.traffic.observedPercent -eq [int]$plan.traffic.holdPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [int]$evidence.traffic.expectedPercent -ne [int]$plan.traffic.holdPercent -or
    [bool]$evidence.traffic.matchesPlan -ne $trafficMatchesPlan -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0
) {
    throw 'The recovery closure traffic evidence is inconsistent with the approved no-mutation plan.'
}
if (
    [string]$evidence.rollback.mode -ne [string]$plan.rollback.mode -or
    [int]$evidence.rollback.targetPercent -ne [int]$plan.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$plan.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$plan.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$plan.rollback.procedureReference -or
    [string]$evidence.rollback.retentionStatus -ne [string]$evidence.verification.rollbackRetention
) {
    throw 'The recovery closure rollback evidence is inconsistent with the approved plan.'
}
if (
    [bool]$evidence.execution.authoritativeExternalSystemRequired -ne $true -or
    [bool]$evidence.execution.performedByRepository -ne $false
) {
    throw 'Recovery closure evidence must preserve external execution and repository read-only separation.'
}

$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$closedAt = ([DateTimeOffset]$evidence.execution.closedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$closureAgeAtCollection = $collectedAt - $closedAt
if (
    $closedAt -lt $approvedAt -or
    $closedAt -gt $expiresAt -or
    $closureAgeAtCollection.TotalMinutes -lt -5 -or
    [int]$evidence.maxClosureAgeMinutes -lt 5 -or
    [int]$evidence.maxClosureAgeMinutes -gt 1440 -or
    $closureAgeAtCollection.TotalMinutes -gt [int]$evidence.maxClosureAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The recovery incident-closure execution or collection timestamp is invalid.'
}

$hasFailure = (
    [string]$evidence.traffic.enforcementStatus -eq 'failed' -or
    [string]$evidence.execution.status -eq 'failed' -or
    [string]$evidence.closure.incidentStatus -eq 'open' -or
    [string]$evidence.closure.changeRecordStatus -eq 'failed' -or
    [string]$evidence.verification.postClosureMonitoring -eq 'degraded' -or
    [string]$evidence.verification.rollbackRetention -eq 'missing' -or
    [string]$evidence.verification.auditEvidence -eq 'incomplete' -or
    -not $trafficMatchesPlan
)
$hasUnknown = @(
    [string]$evidence.traffic.enforcementStatus,
    [string]$evidence.execution.status,
    [string]$evidence.closure.incidentStatus,
    [string]$evidence.closure.changeRecordStatus,
    [string]$evidence.verification.postClosureMonitoring,
    [string]$evidence.verification.rollbackRetention,
    [string]$evidence.verification.auditEvidence
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedClosureRecorded = (
    [string]$evidence.execution.status -eq 'completed' -and
    [string]$evidence.closure.incidentStatus -eq 'closed' -and
    [string]$evidence.closure.changeRecordStatus -eq 'completed'
)
$expectedNextAction = switch ($expectedOutcome) {
    'passed' { 'begin-post-incident-assurance-and-retrospective' }
    'failed' { 'reopen-or-escalate-incident-and-preserve-rollback' }
    default { 'treat-incident-as-open-and-collect-closure-evidence' }
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.closure.recorded -ne $expectedClosureRecorded -or
    [bool]$evidence.decision.closureRecorded -ne $expectedClosureRecorded -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The recovery incident-closure outcome is inconsistent with recorded external evidence.'
}

$integrity = [ordered]@{
    closurePlanSha256 = $planHash
    closurePlanIntegrityDigest = [string]$plan.integrityDigest
    closurePlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    finalExpansionChangeId = [string]$plan.finalExpansionChangeId
    closureChangeId = [string]$plan.closureChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    expectedTrafficPercent = [int]$plan.traffic.holdPercent
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = [string]$evidence.traffic.enforcementStatus
    closureExecutionStatus = [string]$evidence.execution.status
    incidentClosureStatus = [string]$evidence.closure.incidentStatus
    closureChangeRecordStatus = [string]$evidence.closure.changeRecordStatus
    postClosureMonitoringStatus = [string]$evidence.verification.postClosureMonitoring
    rollbackRetentionStatus = [string]$evidence.verification.rollbackRetention
    auditEvidenceStatus = [string]$evidence.verification.auditEvidence
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    closedAtUtc = $closedAt.ToString('o')
    maxClosureAgeMinutes = [int]$evidence.maxClosureAgeMinutes
    closureGateReference = [string]$evidence.externalEvidence.closureGateReference
    incidentClosureReference = [string]$evidence.externalEvidence.incidentClosureReference
    closureChangeRecordReference = [string]$evidence.externalEvidence.closureChangeRecordReference
    postClosureMonitoringReference = [string]$evidence.externalEvidence.postClosureMonitoringReference
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    rollbackRetentionReference = [string]$evidence.externalEvidence.rollbackRetentionReference
    auditEvidenceReference = [string]$evidence.externalEvidence.auditEvidenceReference
    collectedBy = [string]$evidence.externalEvidence.collectedBy
    closureRecorded = $expectedClosureRecorded
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The production recovery incident-closure evidence integrity digest is invalid.'
}

Write-Host "Production recovery incident-closure evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Recorded external incident status: $($evidence.closure.incidentStatus); next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not close or reopen the incident, change traffic, or discard rollback.'
