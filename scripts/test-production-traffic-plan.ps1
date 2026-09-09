[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-traffic/activation.json',
    [string]$BaselineEvidencePath = '',
    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateSet('Pending', 'Approved', 'Either')]
    [string]$RequiredState = 'Approved',

    [ValidateSet('PreActivation', 'PostActivationEvidence')]
    [string]$ValidationPurpose = 'PreActivation',

    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$digestPattern = '^sha256:[0-9a-f]{64}$'
$controlPlaneRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane'
$edgeRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge'
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
    throw "Production traffic activation plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'initial-traffic-activation'
) {
    throw 'The supplied production traffic activation plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The traffic plan uses unsupported namespace '$($plan.namespace)'."
}
if (
    [int]$plan.observationMinutes -lt 5 -or
    [int]$plan.observationMinutes -gt 1440 -or
    [int]$plan.maxBaselineAgeMinutes -lt 5 -or
    [int]$plan.maxBaselineAgeMinutes -gt 1440
) {
    throw 'The traffic plan contains an unsupported time boundary.'
}
if (
    [string]$plan.traffic.currentState -ne 'disabled' -or
    [string]$plan.traffic.requestedState -ne 'canary' -or
    [int]$plan.traffic.canaryPercent -lt 1 -or
    [int]$plan.traffic.canaryPercent -gt 10 -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controller)
) {
    throw 'The initial production traffic request must be an externally enforced canary of 1-10 percent.'
}
if (
    [string]$plan.rollback.mode -ne 'disable-traffic-and-remove-installation' -or
    [string]$plan.rollback.targetState -ne 'absent' -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.authority) -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.procedureReference)
) {
    throw 'The traffic plan must disable traffic before invoking the approved removal path.'
}

$requiredSafeguards = @(
    'exact-production-context'
    'fresh-traffic-disabled-baseline'
    'immutable-candidate-images'
    'bounded-initial-canary'
    'external-traffic-enforcement'
    'disable-before-removal'
    'approved-removal-path'
    'bounded-observation-window'
)
foreach ($requiredSafeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $requiredSafeguard) {
        throw "The traffic activation plan is missing safeguard '$requiredSafeguard'."
    }
}

$resolvedBaselinePath = if ([string]::IsNullOrWhiteSpace($BaselineEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.baselineEvidence.relativePath) -Description 'Recorded baseline evidence path'
}
else {
    Resolve-LocalStatePath -Path $BaselineEvidencePath -Description 'BaselineEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Recorded production baseline evidence is missing: $resolvedBaselinePath"
}
$baselineRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/')
if ($baselineRelativePath -ne [string]$plan.baselineEvidence.relativePath) {
    throw 'The supplied baseline evidence path does not match the traffic plan.'
}
$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($baselineHash -ne [string]$plan.baselineEvidence.sha256) {
    throw 'The production baseline evidence hash does not match the traffic plan.'
}

$baselineValidationArguments = @{
    BaselineEvidencePath = $resolvedBaselinePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($InitialPlanPath)) {
    $baselineValidationArguments.InitialPlanPath = $InitialPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $baselineValidationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-production-baseline-evidence.ps1') @baselineValidationArguments | Out-Null
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json

if (
    [string]$plan.baselineEvidence.integrityDigest -ne [string]$baseline.integrityDigest -or
    [string]$plan.candidate.version -ne [string]$baseline.releaseVersion -or
    [string]$plan.candidate.sourceTag -ne [string]$baseline.sourceTag -or
    [string]$plan.candidate.controlPlaneImage -ne [string]$baseline.images.controlPlane -or
    [string]$plan.candidate.edgeImage -ne [string]$baseline.images.edge -or
    [string]$plan.candidate.policyVersion -ne [string]$baseline.acceptance.edge.policyVersion -or
    [string]$plan.traffic.controller -ne [string]$baseline.traffic.controller
) {
    throw 'The traffic activation plan no longer matches the production baseline.'
}

foreach ($imageContract in @(
    [pscustomobject]@{ Image = [string]$plan.candidate.controlPlaneImage; Repository = $controlPlaneRepository }
    [pscustomobject]@{ Image = [string]$plan.candidate.edgeImage; Repository = $edgeRepository }
)) {
    if ($imageContract.Image -notmatch "^$([regex]::Escape($imageContract.Repository))@sha256:[0-9a-f]{64}$") {
        throw "Traffic plan image is not an approved digest-pinned reference: $($imageContract.Image)"
    }
}
if ([string]$plan.candidate.policyVersion -notmatch $digestPattern) {
    throw 'The traffic plan does not contain a verified policy digest.'
}

$collectedAt = [DateTimeOffset]$baseline.collectedAtUtc
$baselineAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
if (
    $ValidationPurpose -eq 'PreActivation' -and
    ($baselineAge.TotalMinutes -lt -5 -or $baselineAge.TotalMinutes -gt [int]$plan.maxBaselineAgeMinutes)
) {
    throw 'The production baseline evidence is stale. Traffic activation is blocked.'
}

$resolvedInitialPlanPath = if ([string]::IsNullOrWhiteSpace($InitialPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$baseline.initialPlan.relativePath) -Description 'Recorded initial plan path'
}
else {
    Resolve-LocalStatePath -Path $InitialPlanPath -Description 'InitialPlanPath'
}
$initialPlan = Get-Content -Raw -LiteralPath $resolvedInitialPlanPath | ConvertFrom-Json
if (
    [string]$plan.rollback.authority -ne [string]$initialPlan.rollback.authority -or
    [string]$plan.rollback.procedureReference -ne [string]$initialPlan.rollback.procedureReference
) {
    throw 'The traffic plan removal path does not match the approved initial installation plan.'
}

$integrity = [ordered]@{
    baselineEvidenceSha256 = [string]$plan.baselineEvidence.sha256
    productionContext = [string]$plan.productionContext
    namespace = [string]$plan.namespace
    changeId = [string]$plan.changeId
    releaseVersion = [string]$plan.candidate.version
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    currentTrafficState = [string]$plan.traffic.currentState
    requestedTrafficState = [string]$plan.traffic.requestedState
    canaryPercent = [int]$plan.traffic.canaryPercent
    trafficController = [string]$plan.traffic.controller
    rollbackMode = [string]$plan.rollback.mode
    removalAuthority = [string]$plan.rollback.authority
    removalProcedureReference = [string]$plan.rollback.procedureReference
    observationMinutes = [int]$plan.observationMinutes
    maxBaselineAgeMinutes = [int]$plan.maxBaselineAgeMinutes
    approvalOwner = [string]$plan.approval.owner
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$plan.integrityDigest) {
    throw 'The production traffic activation plan integrity digest is invalid.'
}

$state = [string]$plan.state
$approvalStatus = [string]$plan.approval.status
if ($ValidationPurpose -eq 'PostActivationEvidence' -and $RequiredState -ne 'Approved') {
    throw 'Post-activation evidence may only use an approved traffic activation plan.'
}
if ($RequiredState -eq 'Pending' -and ($state -ne 'pending' -or $approvalStatus -ne 'pending')) {
    throw "The production traffic activation plan is '$state'; expected pending."
}
if ($RequiredState -eq 'Approved' -and ($state -ne 'approved' -or $approvalStatus -ne 'approved')) {
    throw "The production traffic activation plan is '$state'; expected approved."
}
if ($RequiredState -eq 'Either' -and $state -notin @('pending', 'approved')) {
    throw "The production traffic activation plan has unsupported state '$state'."
}

$requiredStatement = "APPROVE $($plan.traffic.canaryPercent)% CANARY $($plan.changeId) FOR $($plan.productionContext) RELEASE $($plan.candidate.version)"
if ([string]$plan.approval.requiredStatement -ne $requiredStatement) {
    throw 'The production canary approval statement is inconsistent with the plan.'
}
if ($state -eq 'approved') {
    if (
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $requiredStatement
    ) {
        throw 'The production canary approval identity or statement is invalid.'
    }
    try {
        $approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
    }
    catch {
        throw 'The production canary approval timestamp is invalid.'
    }
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if ($approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds()) {
        throw 'The production canary approval timestamp and Unix time do not agree.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The production canary approval digest is invalid.'
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
    throw 'A pending traffic activation plan contains an inconsistent approval state.'
}

Write-Host "Production traffic activation plan validation passed for $($plan.traffic.canaryPercent)% canary."
Write-Host 'This validation records authorization; it does not enforce or change traffic routing.'
