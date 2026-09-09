[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-progressive/expansion.json',
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

    [ValidateSet('Pending', 'Approved', 'Either')]
    [string]$RequiredState = 'Approved',

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
    throw "Production progressive expansion plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'progressive-traffic-expansion'
) {
    throw 'The supplied production progressive expansion plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The progressive expansion plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The progressive expansion plan uses unsupported namespace '$($plan.namespace)'."
}
if (
    [int]$plan.observationMinutes -lt 5 -or
    [int]$plan.observationMinutes -gt 1440 -or
    [int]$plan.maxEvidenceAgeMinutes -lt 5 -or
    [int]$plan.maxEvidenceAgeMinutes -gt 1440
) {
    throw 'The progressive expansion plan contains an unsupported time boundary.'
}
if (
    [int]$plan.traffic.currentPercent -lt 2 -or
    [int]$plan.traffic.currentPercent -gt 25 -or
    [int]$plan.traffic.targetPercent -le [int]$plan.traffic.currentPercent -or
    [int]$plan.traffic.targetPercent -gt 50 -or
    ([int]$plan.traffic.targetPercent - [int]$plan.traffic.currentPercent) -gt 25 -or
    [int]$plan.traffic.maximumTargetPercent -ne 50 -or
    [int]$plan.traffic.maximumStepPercentagePoints -ne 25 -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controller) -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controllerChangeReference)
) {
    throw 'The progressive expansion must increase traffic by at most 25 percentage points without exceeding 50 percent.'
}
if (
    [string]$plan.rollback.mode -ne 'restore-previous-cohort-or-disable-and-remove' -or
    [int]$plan.rollback.targetPercent -ne [int]$plan.traffic.currentPercent -or
    [int]$plan.rollback.emergencyTargetPercent -ne 0 -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.authority) -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.procedureReference)
) {
    throw 'The progressive expansion plan must restore the previous cohort or preserve emergency disable-before-removal.'
}

$requiredSafeguards = @(
    'passed-first-expansion-evidence'
    'fresh-observation-evidence'
    'immutable-candidate-images'
    'bounded-progressive-step'
    'maximum-half-traffic'
    'external-traffic-enforcement'
    'separate-expansion-approval'
    'restore-previous-cohort'
    'emergency-disable-before-removal'
    'bounded-observation-window'
)
foreach ($requiredSafeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $requiredSafeguard) {
        throw "The progressive expansion plan is missing safeguard '$requiredSafeguard'."
    }
}

$resolvedEvidencePath = if ([string]::IsNullOrWhiteSpace($ExpansionEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.expansionEvidence.relativePath) -Description 'Recorded expansion evidence path'
}
else {
    Resolve-LocalStatePath -Path $ExpansionEvidencePath -Description 'ExpansionEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Recorded production first-expansion evidence is missing: $resolvedEvidencePath"
}
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $evidenceRelativePath -ne [string]$plan.expansionEvidence.relativePath -or
    $evidenceHash -ne [string]$plan.expansionEvidence.sha256
) {
    throw 'The production first-expansion evidence hash does not match the progressive plan.'
}

$evidenceValidationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'CanaryEvidencePath'; Value = $CanaryEvidencePath }
    [pscustomobject]@{ Name = 'TrafficPlanPath'; Value = $TrafficPlanPath }
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $evidenceValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-expansion-evidence.ps1') @evidenceValidationArguments | Out-Null
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$plan.expansionEvidence.outcome -ne 'passed' -or
    [string]$plan.expansionEvidence.integrityDigest -ne [string]$evidence.integrityDigest -or
    ([DateTimeOffset]$plan.expansionEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -ne ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    ([DateTimeOffset]$plan.expansionEvidence.observationEndedAtUtc).ToUniversalTime().ToString('o') -ne ([DateTimeOffset]$evidence.observation.endedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$plan.traffic.currentPercent -ne [int]$evidence.observation.observedTrafficPercent -or
    [string]$plan.traffic.controller -ne [string]$evidence.traffic.controller -or
    [string]$plan.traffic.controllerChangeReference -ne [string]$evidence.externalEvidence.trafficChangeReference -or
    [string]$plan.candidate.version -ne [string]$evidence.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$evidence.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$evidence.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$evidence.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$evidence.candidate.policyVersion
) {
    throw 'The progressive expansion plan no longer matches passed first-expansion evidence.'
}

$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
$observationEndedAt = [DateTimeOffset]$evidence.observation.endedAtUtc
$observationAge = [DateTimeOffset]::UtcNow - $observationEndedAt.ToUniversalTime()
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt [int]$plan.maxEvidenceAgeMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt [int]$plan.maxEvidenceAgeMinutes
) {
    throw 'The production first-expansion evidence is stale. Progressive expansion is blocked.'
}
if (
    [string]$plan.rollback.authority -ne [string]$evidence.rollback.authority -or
    [string]$plan.rollback.procedureReference -ne [string]$evidence.rollback.procedureReference
) {
    throw 'The progressive rollback authority no longer matches first-expansion evidence.'
}

$integrity = [ordered]@{
    expansionEvidenceSha256 = [string]$plan.expansionEvidence.sha256
    expansionEvidenceIntegrityDigest = [string]$plan.expansionEvidence.integrityDigest
    productionContext = [string]$plan.productionContext
    namespace = [string]$plan.namespace
    changeId = [string]$plan.changeId
    releaseVersion = [string]$plan.candidate.version
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    currentTrafficPercent = [int]$plan.traffic.currentPercent
    targetTrafficPercent = [int]$plan.traffic.targetPercent
    maximumTargetPercent = [int]$plan.traffic.maximumTargetPercent
    maximumStepPercentagePoints = [int]$plan.traffic.maximumStepPercentagePoints
    trafficController = [string]$plan.traffic.controller
    controllerChangeReference = [string]$plan.traffic.controllerChangeReference
    rollbackMode = [string]$plan.rollback.mode
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    observationMinutes = [int]$plan.observationMinutes
    maxEvidenceAgeMinutes = [int]$plan.maxEvidenceAgeMinutes
    approvalOwner = [string]$plan.approval.owner
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production progressive expansion plan integrity digest is invalid.'
}

$state = [string]$plan.state
$approvalStatus = [string]$plan.approval.status
if ($RequiredState -eq 'Pending' -and ($state -ne 'pending' -or $approvalStatus -ne 'pending')) {
    throw "The production progressive expansion plan is '$state'; expected pending."
}
if ($RequiredState -eq 'Approved' -and ($state -ne 'approved' -or $approvalStatus -ne 'approved')) {
    throw "The production progressive expansion plan is '$state'; expected approved."
}
if ($RequiredState -eq 'Either' -and $state -notin @('pending', 'approved')) {
    throw "The production progressive expansion plan has unsupported state '$state'."
}

$requiredStatement = "APPROVE EXPANSION TO $($plan.traffic.targetPercent)% $($plan.changeId) FOR $($plan.productionContext) RELEASE $($plan.candidate.version)"
if ([string]$plan.approval.requiredStatement -ne $requiredStatement) {
    throw 'The production progressive expansion approval statement is inconsistent with the plan.'
}
if ($state -eq 'approved') {
    if (
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $requiredStatement
    ) {
        throw 'The production progressive expansion approval identity or statement is invalid.'
    }
    try {
        $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    }
    catch {
        throw 'The production progressive expansion approval timestamp is invalid.'
    }
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if ($approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds()) {
        throw 'The production progressive expansion approval timestamp and Unix time do not agree.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The production progressive expansion approval digest is invalid.'
    }
}
elseif (
    $approvalStatus -ne 'pending' -or
    $null -ne $plan.approval.approvedBy -or
    $null -ne $plan.approval.approvedAtUtc -or
    $null -ne $plan.approval.approvedAtUnixSeconds -or
    $null -ne $plan.approval.approvalStatement -or
    $null -ne $plan.approval.approvalDigest
) {
    throw 'A pending progressive expansion plan contains an inconsistent approval state.'
}

Write-Host "Production progressive expansion plan validation passed for $($plan.traffic.currentPercent)% to $($plan.traffic.targetPercent)%."
Write-Host 'This validation records authorization; it does not enforce or change traffic routing.'
