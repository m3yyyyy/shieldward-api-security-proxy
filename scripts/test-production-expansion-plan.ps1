[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-expansion/expansion.json',
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
    throw "Production expansion plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'initial-traffic-expansion'
) {
    throw 'The supplied production expansion plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The expansion plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The expansion plan uses unsupported namespace '$($plan.namespace)'."
}
if (
    [int]$plan.observationMinutes -lt 5 -or
    [int]$plan.observationMinutes -gt 1440 -or
    [int]$plan.maxEvidenceAgeMinutes -lt 5 -or
    [int]$plan.maxEvidenceAgeMinutes -gt 1440
) {
    throw 'The expansion plan contains an unsupported time boundary.'
}
if (
    [int]$plan.traffic.currentPercent -lt 1 -or
    [int]$plan.traffic.currentPercent -gt 10 -or
    [int]$plan.traffic.targetPercent -le [int]$plan.traffic.currentPercent -or
    [int]$plan.traffic.targetPercent -gt 25 -or
    [int]$plan.traffic.maximumInitialExpansionPercent -ne 25 -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controller) -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controllerChangeReference)
) {
    throw 'The first production expansion must increase the canary without exceeding 25 percent.'
}
if (
    [string]$plan.rollback.mode -ne 'disable-traffic-and-remove-installation' -or
    [string]$plan.rollback.targetState -ne 'absent' -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.authority) -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.procedureReference)
) {
    throw 'The expansion plan must preserve the approved disable-before-removal path.'
}

$requiredSafeguards = @(
    'passed-canary-evidence'
    'fresh-observation-evidence'
    'immutable-candidate-images'
    'bounded-first-expansion'
    'external-traffic-enforcement'
    'separate-expansion-approval'
    'disable-before-removal'
    'bounded-observation-window'
)
foreach ($requiredSafeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $requiredSafeguard) {
        throw "The expansion plan is missing safeguard '$requiredSafeguard'."
    }
}

$resolvedCanaryEvidencePath = if ([string]::IsNullOrWhiteSpace($CanaryEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.canaryEvidence.relativePath) -Description 'Recorded canary evidence path'
}
else {
    Resolve-LocalStatePath -Path $CanaryEvidencePath -Description 'CanaryEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedCanaryEvidencePath -PathType Leaf)) {
    throw "Recorded production canary evidence is missing: $resolvedCanaryEvidencePath"
}
$canaryEvidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedCanaryEvidencePath).Replace('\', '/')
$canaryEvidenceHash = (Get-FileHash -LiteralPath $resolvedCanaryEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $canaryEvidenceRelativePath -ne [string]$plan.canaryEvidence.relativePath -or
    $canaryEvidenceHash -ne [string]$plan.canaryEvidence.sha256
) {
    throw 'The production canary evidence hash does not match the expansion plan.'
}

$evidenceValidationArguments = @{
    EvidencePath = $resolvedCanaryEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'TrafficPlanPath'; Value = $TrafficPlanPath }
    [pscustomobject]@{ Name = 'BaselineEvidencePath'; Value = $BaselineEvidencePath }
    [pscustomobject]@{ Name = 'InitialPlanPath'; Value = $InitialPlanPath }
    [pscustomobject]@{ Name = 'StagingEvidencePath'; Value = $StagingEvidencePath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $evidenceValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
& (Join-Path $PSScriptRoot 'test-production-canary-evidence.ps1') @evidenceValidationArguments | Out-Null
$canaryEvidence = Get-Content -Raw -LiteralPath $resolvedCanaryEvidencePath | ConvertFrom-Json
if (
    [string]$canaryEvidence.outcome -ne 'passed' -or
    [string]$plan.canaryEvidence.outcome -ne 'passed' -or
    [string]$plan.canaryEvidence.integrityDigest -ne [string]$canaryEvidence.integrityDigest -or
    ([DateTimeOffset]$plan.canaryEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -ne ([DateTimeOffset]$canaryEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    [int]$plan.traffic.currentPercent -ne [int]$canaryEvidence.observation.observedCanaryPercent -or
    [string]$plan.traffic.controller -ne [string]$canaryEvidence.traffic.controller -or
    [string]$plan.traffic.controllerChangeReference -ne [string]$canaryEvidence.externalEvidence.trafficChangeReference -or
    [string]$plan.candidate.version -ne [string]$canaryEvidence.candidate.version -or
    [string]$plan.candidate.sourceTag -ne [string]$canaryEvidence.candidate.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$canaryEvidence.candidate.controlPlaneImage -or
    [string]$plan.candidate.edgeImage -ne [string]$canaryEvidence.candidate.edgeImage -or
    [string]$plan.candidate.policyVersion -ne [string]$canaryEvidence.candidate.policyVersion
) {
    throw 'The expansion plan no longer matches passed canary evidence.'
}

$collectedAt = [DateTimeOffset]$canaryEvidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
$observationEndedAt = [DateTimeOffset]$canaryEvidence.observation.endedAtUtc
$observationAge = [DateTimeOffset]::UtcNow - $observationEndedAt.ToUniversalTime()
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt [int]$plan.maxEvidenceAgeMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt [int]$plan.maxEvidenceAgeMinutes
) {
    throw 'The production canary evidence is stale. Traffic expansion is blocked.'
}
if (
    [string]$plan.rollback.mode -ne [string]$canaryEvidence.rollback.mode -or
    [string]$plan.rollback.targetState -ne [string]$canaryEvidence.rollback.targetState -or
    [string]$plan.rollback.authority -ne [string]$canaryEvidence.rollback.authority -or
    [string]$plan.rollback.procedureReference -ne [string]$canaryEvidence.rollback.procedureReference
) {
    throw 'The expansion rollback path no longer matches the canary evidence.'
}

$integrity = [ordered]@{
    canaryEvidenceSha256 = [string]$plan.canaryEvidence.sha256
    canaryEvidenceIntegrityDigest = [string]$plan.canaryEvidence.integrityDigest
    productionContext = [string]$plan.productionContext
    namespace = [string]$plan.namespace
    changeId = [string]$plan.changeId
    releaseVersion = [string]$plan.candidate.version
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    currentTrafficPercent = [int]$plan.traffic.currentPercent
    targetTrafficPercent = [int]$plan.traffic.targetPercent
    trafficController = [string]$plan.traffic.controller
    controllerChangeReference = [string]$plan.traffic.controllerChangeReference
    rollbackMode = [string]$plan.rollback.mode
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    observationMinutes = [int]$plan.observationMinutes
    maxEvidenceAgeMinutes = [int]$plan.maxEvidenceAgeMinutes
    approvalOwner = [string]$plan.approval.owner
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production expansion plan integrity digest is invalid.'
}

$state = [string]$plan.state
$approvalStatus = [string]$plan.approval.status
if ($RequiredState -eq 'Pending' -and ($state -ne 'pending' -or $approvalStatus -ne 'pending')) {
    throw "The production expansion plan is '$state'; expected pending."
}
if ($RequiredState -eq 'Approved' -and ($state -ne 'approved' -or $approvalStatus -ne 'approved')) {
    throw "The production expansion plan is '$state'; expected approved."
}
if ($RequiredState -eq 'Either' -and $state -notin @('pending', 'approved')) {
    throw "The production expansion plan has unsupported state '$state'."
}

$requiredStatement = "APPROVE EXPANSION TO $($plan.traffic.targetPercent)% $($plan.changeId) FOR $($plan.productionContext) RELEASE $($plan.candidate.version)"
if ([string]$plan.approval.requiredStatement -ne $requiredStatement) {
    throw 'The production expansion approval statement is inconsistent with the plan.'
}
if ($state -eq 'approved') {
    if (
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $requiredStatement
    ) {
        throw 'The production expansion approval identity or statement is invalid.'
    }
    try {
        $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    }
    catch {
        throw 'The production expansion approval timestamp is invalid.'
    }
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if ($approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds()) {
        throw 'The production expansion approval timestamp and Unix time do not agree.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The production expansion approval digest is invalid.'
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
    throw 'A pending expansion plan contains an inconsistent approval state.'
}

Write-Host "Production traffic expansion plan validation passed for $($plan.traffic.currentPercent)% to $($plan.traffic.targetPercent)%."
Write-Host 'This validation records authorization; it does not enforce or change traffic routing.'
