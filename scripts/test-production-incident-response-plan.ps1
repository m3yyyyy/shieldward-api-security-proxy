[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-response/response.json',
    [string]$AssuranceEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateSet('Any', 'Pending', 'Approved')]
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
        [Parameter(Mandatory)][string]$Description
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 128 -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most 128 characters without control characters."
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
    throw "Production incident response plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'production-incident-response'
) {
    throw 'The supplied production incident response plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The incident response plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The incident response plan uses unsupported namespace '$($plan.namespace)'."
}
if ([string]$plan.incidentId -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$') {
    throw 'The incident response plan has an invalid incident identifier.'
}
if ([string]$plan.changeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$') {
    throw 'The incident response plan has an invalid change identifier.'
}
Assert-OperatorValue -Value ([string]$plan.incidentId) -Description 'IncidentId'
Assert-OperatorValue -Value ([string]$plan.changeId) -Description 'ChangeId'
Assert-OperatorValue -Value ([string]$plan.response.authority) -Description 'Response authority'

$resolvedEvidencePath = if ([string]::IsNullOrWhiteSpace($AssuranceEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.assuranceEvidence.relativePath) -Description 'Recorded assurance evidence path'
}
else {
    Resolve-LocalStatePath -Path $AssuranceEvidencePath -Description 'AssuranceEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Recorded production assurance evidence is missing: $resolvedEvidencePath"
}

& (Join-Path $PSScriptRoot 'test-production-assurance-evidence.ps1') `
    -EvidencePath $resolvedEvidencePath `
    -ExpectedProductionContext $ExpectedProductionContext `
    -CheckCluster:$CheckCluster 6>$null

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if ([string]$evidence.outcome -notin @('failed', 'unknown')) {
    throw "Incident response planning requires failed or unknown assurance evidence; outcome is '$($evidence.outcome)'."
}
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $evidenceRelativePath -ne [string]$plan.assuranceEvidence.relativePath -or
    $evidenceHash -ne [string]$plan.assuranceEvidence.sha256 -or
    [string]$evidence.integrityDigest -ne [string]$plan.assuranceEvidence.integrityDigest -or
    [string]$evidence.outcome -ne [string]$plan.assuranceEvidence.outcome -or
    [string]$evidence.decision.requiredAction -ne [string]$plan.assuranceEvidence.requiredAction
) {
    throw 'The production assurance evidence no longer matches the incident response plan.'
}

$allowedResponseActions = switch ([string]$evidence.decision.requiredAction) {
    'reaccept-before-continuing' { @('reaccept-before-continuing') }
    'disable-and-investigate' { @('disable-and-investigate') }
    'rotate-certificates-and-refresh-evidence' { @('rotate-certificates-and-refresh-evidence') }
    'rollback-or-disable-and-investigate' { @('rollback-to-75-and-investigate', 'disable-and-investigate') }
    'investigate-and-refresh-evidence' { @('investigate-and-refresh-evidence', 'disable-and-investigate') }
    default { throw "Unsupported assurance action '$($evidence.decision.requiredAction)'." }
}
$responseAction = [string]$plan.response.action
if ($responseAction -notin $allowedResponseActions) {
    throw "Response action '$responseAction' is not allowed for assurance action '$($evidence.decision.requiredAction)'."
}

$expectedTargetPercent = switch ($responseAction) {
    'disable-and-investigate' { 0 }
    'rollback-to-75-and-investigate' { [int]$evidence.rollback.targetPercent }
    default { [int]$evidence.traffic.observedTrafficPercent }
}
if (
    [int]$plan.traffic.currentPercent -ne [int]$evidence.traffic.observedTrafficPercent -or
    [int]$plan.traffic.targetPercent -ne $expectedTargetPercent -or
    [string]$plan.traffic.controller -ne [string]$evidence.traffic.controller -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true
) {
    throw 'The incident response traffic boundary is inconsistent with assurance evidence.'
}
if ($responseAction -eq 'rollback-to-75-and-investigate' -and $expectedTargetPercent -ne 75) {
    throw 'The incident response plan does not have an exact 75 percent rollback cohort.'
}
if (
    [string]$plan.response.authority -ne [string]$evidence.rollback.authority -or
    [string]$plan.response.procedureReference -ne [string]$evidence.rollback.procedureReference -or
    [bool]$plan.response.externalIncidentSystemRequired -ne $true -or
    [bool]$plan.response.externalTrafficControllerRequired -ne $true -or
    [string]$plan.response.executionState -ne 'not-started'
) {
    throw 'The incident response authority or external execution boundary is invalid.'
}
if (
    [string]$plan.decision.sourceAction -ne [string]$evidence.decision.requiredAction -or
    [bool]$plan.decision.reacceptanceRequired -ne [bool]$evidence.decision.reacceptanceRequired
) {
    throw 'The incident response decision no longer matches assurance evidence.'
}
if (
    [string]$plan.rollback.mode -ne [string]$evidence.rollback.mode -or
    [int]$plan.rollback.targetPercent -ne [int]$evidence.rollback.targetPercent -or
    [int]$plan.rollback.emergencyTargetPercent -ne [int]$evidence.rollback.emergencyTargetPercent -or
    [string]$plan.rollback.authority -ne [string]$evidence.rollback.authority -or
    [string]$plan.rollback.procedureReference -ne [string]$evidence.rollback.procedureReference
) {
    throw 'The incident response plan no longer matches the accepted rollback boundary.'
}
if (
    [string]$plan.candidate.version -ne [string]$evidence.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$evidence.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$evidence.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$evidence.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$evidence.candidate.policyVersion
) {
    throw 'The incident response candidate no longer matches assurance evidence.'
}

$generatedAt = [DateTimeOffset]$plan.generatedAtUtc
$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$deadlineAt = [DateTimeOffset]$plan.response.deadlineAtUtc
$evidenceAgeAtGeneration = $generatedAt.ToUniversalTime() - $collectedAt.ToUniversalTime()
if (
    [int]$plan.maxEvidenceAgeMinutes -lt 5 -or
    [int]$plan.maxEvidenceAgeMinutes -gt 1440 -or
    $evidenceAgeAtGeneration.TotalMinutes -lt -5 -or
    $evidenceAgeAtGeneration.TotalMinutes -gt [int]$plan.maxEvidenceAgeMinutes
) {
    throw 'The assurance evidence was outside the recorded response age when the plan was generated.'
}
$deadlineSpan = $deadlineAt.ToUniversalTime() - $generatedAt.ToUniversalTime()
if (
    [int]$plan.responseDeadlineMinutes -lt 5 -or
    [int]$plan.responseDeadlineMinutes -gt 1440 -or
    [Math]::Abs($deadlineSpan.TotalMinutes - [int]$plan.responseDeadlineMinutes) -gt 0.01
) {
    throw 'The incident response deadline is inconsistent with the recorded response window.'
}
if ([string]$plan.state -eq 'pending' -and [DateTimeOffset]::UtcNow -gt $deadlineAt.ToUniversalTime()) {
    throw 'The pending incident response plan has exceeded its response deadline.'
}

$expectedApprovalStatement = "APPROVE PRODUCTION INCIDENT RESPONSE $($plan.incidentId) $($plan.changeId) FOR $ExpectedProductionContext ACTION $responseAction"
if (
    [string]$plan.approval.owner -ne [string]$plan.response.authority -or
    [string]$plan.approval.requiredStatement -ne $expectedApprovalStatement
) {
    throw 'The incident response approval contract is invalid.'
}

$integrity = [ordered]@{
    assuranceEvidenceSha256 = $evidenceHash
    assuranceEvidenceIntegrityDigest = [string]$evidence.integrityDigest
    assuranceOutcome = [string]$evidence.outcome
    assuranceRequiredAction = [string]$evidence.decision.requiredAction
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    changeId = [string]$plan.changeId
    generatedAtUtc = $generatedAt.ToUniversalTime().ToString('o')
    responseDeadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
    responseDeadlineMinutes = [int]$plan.responseDeadlineMinutes
    maxEvidenceAgeMinutes = [int]$plan.maxEvidenceAgeMinutes
    releaseVersion = [string]$evidence.candidate.version
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    currentTrafficPercent = [int]$evidence.traffic.observedTrafficPercent
    targetTrafficPercent = $expectedTargetPercent
    trafficController = [string]$evidence.traffic.controller
    responseAction = $responseAction
    responseOwner = [string]$plan.response.authority
    rollbackAuthority = [string]$evidence.rollback.authority
    rollbackProcedureReference = [string]$evidence.rollback.procedureReference
    reacceptanceRequired = [bool]$evidence.decision.reacceptanceRequired
}
$expectedIntegrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)
if ($expectedIntegrityDigest -ne [string]$plan.integrityDigest) {
    throw 'The production incident response plan integrity digest is invalid.'
}

$requiredSafeguards = @(
    'failed-or-unknown-assurance-evidence',
    'fresh-response-evidence',
    'immutable-assurance-evidence',
    'exact-production-context',
    'explicit-incident-and-change-records',
    'recorded-response-authority',
    'explicit-response-action',
    'bounded-response-deadline',
    'external-traffic-enforcement',
    'no-automatic-production-mutation',
    'preserve-audit-evidence'
)
foreach ($safeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $safeguard) {
        throw "The incident response plan is missing safeguard '$safeguard'."
    }
}

if ([string]$plan.state -eq 'pending') {
    if (
        [string]$plan.approval.status -ne 'pending' -or
        $null -ne $plan.approval.approvedBy -or
        $null -ne $plan.approval.approvedAtUtc -or
        $null -ne $plan.approval.approvedAtUnixSeconds -or
        $null -ne $plan.approval.approvalStatement -or
        $null -ne $plan.approval.approvalDigest
    ) {
        throw 'The pending incident response plan contains approval data.'
    }
}
elseif ([string]$plan.state -eq 'approved') {
    if (
        [string]$plan.approval.status -ne 'approved' -or
        [string]::IsNullOrWhiteSpace([string]$plan.approval.approvedBy) -or
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $expectedApprovalStatement
    ) {
        throw 'The approved incident response plan has invalid approval data.'
    }
    $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if (
        $approvedAt.ToUnixTimeSeconds() -ne $approvedAtUnixSeconds -or
        $approvedAt.ToUniversalTime() -lt $generatedAt.ToUniversalTime() -or
        $approvedAt.ToUniversalTime() -gt $deadlineAt.ToUniversalTime()
    ) {
        throw 'The incident response approval timestamp is invalid or outside the response deadline.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The incident response approval digest is invalid.'
    }
}
else {
    throw "Unsupported incident response plan state '$($plan.state)'."
}

if ($RequiredState -ne 'Any' -and [string]$plan.state -ne $RequiredState.ToLowerInvariant()) {
    throw "Incident response plan state is '$($plan.state)'; expected '$($RequiredState.ToLowerInvariant())'."
}

Write-Host "Production incident response plan validation passed for incident $($plan.incidentId)."
Write-Host "Response action: $responseAction; target traffic: $expectedTargetPercent%."
Write-Host 'This validator is read-only and does not authorize or execute production changes.'
