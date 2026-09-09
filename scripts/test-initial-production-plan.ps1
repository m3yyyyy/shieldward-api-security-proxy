[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-initial/installation.json',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateSet('Pending', 'Approved', 'Either')]
    [string]$RequiredState = 'Approved',

    [switch]$CheckCurrentContext,
    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

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
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Description
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
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($sha256.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& kubectl --context $ExpectedProductionContext @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return $output
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Initial production installation plan is missing: $resolvedPlanPath"
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
if (
    [int]$plan.schemaVersion -ne 1 -or
    [string]$plan.environment -ne 'production' -or
    [string]$plan.operation -ne 'initial-installation'
) {
    throw 'The supplied initial production installation plan is unsupported.'
}
if ([string]$plan.productionContext -ne $ExpectedProductionContext) {
    throw "The plan targets '$($plan.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$plan.namespace -ne 'shieldward') {
    throw "The installation plan uses unsupported namespace '$($plan.namespace)'."
}
if ([string]$plan.stagingEvidence.context -eq $ExpectedProductionContext) {
    throw 'The production context must be different from the staging context.'
}
if ([int]$plan.observationMinutes -lt 5 -or [int]$plan.observationMinutes -gt 1440) {
    throw 'The production observation window is outside the supported range.'
}
if (
    [string]$plan.traffic.desiredState -ne 'disabled' -or
    [bool]$plan.traffic.externalEnforcementRequired -ne $true -or
    [string]::IsNullOrWhiteSpace([string]$plan.traffic.controller)
) {
    throw 'Initial production traffic must remain disabled by the recorded external controller.'
}
if (
    [string]$plan.rollback.mode -ne 'remove-installation' -or
    [string]$plan.rollback.targetState -ne 'absent' -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.authority) -or
    [string]::IsNullOrWhiteSpace([string]$plan.rollback.procedureReference)
) {
    throw 'The initial installation must contain an approved removal path to an absent state.'
}

$requiredSafeguards = @(
    'exact-production-context'
    'initial-empty-baseline'
    'traffic-disabled'
    'immutable-candidate-images'
    'verified-staging-evidence'
    'approved-removal-path'
    'bounded-observation-window'
)
foreach ($requiredSafeguard in $requiredSafeguards) {
    if (@($plan.safeguards) -notcontains $requiredSafeguard) {
        throw "The initial installation plan is missing safeguard '$requiredSafeguard'."
    }
}

$resolvedEvidencePath = if ([string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$plan.stagingEvidence.relativePath) -Description 'Recorded staging evidence path'
}
else {
    Resolve-LocalStatePath -Path $StagingEvidencePath -Description 'StagingEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Recorded staging evidence is missing: $resolvedEvidencePath"
}
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
if ($evidenceRelativePath -ne [string]$plan.stagingEvidence.relativePath) {
    throw 'The supplied staging evidence path does not match the installation plan.'
}
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($evidenceHash -ne [string]$plan.stagingEvidence.sha256) {
    throw 'The staging evidence hash does not match the installation plan. Installation is blocked.'
}

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'staging' -or
    [string]$evidence.kubernetesContext -ne [string]$plan.stagingEvidence.context -or
    [string]$evidence.releaseVersion -ne [string]$plan.candidate.version -or
    [string]$evidence.sourceTag -ne [string]$plan.candidate.sourceTag -or
    [string]$evidence.images.controlPlane -ne [string]$plan.candidate.controlPlaneImage -or
    [string]$evidence.images.edge -ne [string]$plan.candidate.edgeImage
) {
    throw 'The staging evidence no longer matches the initial production candidate.'
}

$policyVersion = [string]$plan.stagingEvidence.policyVersion
if ($policyVersion -notmatch $digestPattern) {
    throw 'The installation plan does not contain a verified staging policy digest.'
}
foreach ($phaseName in @('steadyState', 'controlPlaneOutage', 'recovery')) {
    $phase = $evidence.checks.$phaseName
    if (
        $null -eq $phase -or
        [string]$phase.healthStatus -ne 'ok' -or
        [string]$phase.readyStatus -ne 'ready' -or
        [string]$phase.runtimeVersion -ne [string]$plan.candidate.version -or
        [string]$phase.policyVersion -ne $policyVersion -or
        [int]$phase.defaultDenyStatus -ne 403 -or
        [int]$phase.protectedRouteStatus -ne 401
    ) {
        throw "The recorded staging phase $phaseName is not initial-production ready."
    }
}
if ([string]$evidence.checks.controlPlaneRuntimeVersion -ne [string]$plan.candidate.version) {
    throw 'The control-plane runtime version no longer matches the installation candidate.'
}

$candidateControlPlaneImage = [string]$plan.candidate.controlPlaneImage
$candidateEdgeImage = [string]$plan.candidate.edgeImage
foreach ($imageContract in @(
    [pscustomobject]@{ Image = $candidateControlPlaneImage; Repository = $controlPlaneRepository }
    [pscustomobject]@{ Image = $candidateEdgeImage; Repository = $edgeRepository }
)) {
    if ($imageContract.Image -notmatch "^$([regex]::Escape($imageContract.Repository))@sha256:[0-9a-f]{64}$") {
        throw "Installation plan image is not an approved digest-pinned reference: $($imageContract.Image)"
    }
}

$integrity = [ordered]@{
    stagingEvidenceSha256 = [string]$plan.stagingEvidence.sha256
    productionContext = [string]$plan.productionContext
    namespace = [string]$plan.namespace
    changeId = [string]$plan.changeId
    candidateVersion = [string]$plan.candidate.version
    candidateControlPlane = $candidateControlPlaneImage
    candidateEdge = $candidateEdgeImage
    trafficState = [string]$plan.traffic.desiredState
    trafficController = [string]$plan.traffic.controller
    rollbackMode = [string]$plan.rollback.mode
    removalAuthority = [string]$plan.rollback.authority
    removalProcedureReference = [string]$plan.rollback.procedureReference
    observationMinutes = [int]$plan.observationMinutes
    approvalOwner = [string]$plan.approval.owner
}
$expectedIntegrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)
if ($expectedIntegrityDigest -ne [string]$plan.integrityDigest) {
    throw 'The initial production installation plan integrity digest is invalid. Installation is blocked.'
}

$state = [string]$plan.state
$approvalStatus = [string]$plan.approval.status
if ($RequiredState -eq 'Pending' -and ($state -ne 'pending' -or $approvalStatus -ne 'pending')) {
    throw "The initial production installation plan is '$state'; expected pending."
}
if ($RequiredState -eq 'Approved' -and ($state -ne 'approved' -or $approvalStatus -ne 'approved')) {
    throw "The initial production installation plan is '$state'; expected approved."
}
if ($RequiredState -eq 'Either' -and $state -notin @('pending', 'approved')) {
    throw "The initial production installation plan has unsupported state '$state'."
}

$requiredStatement = "APPROVE INITIAL INSTALL $($plan.changeId) FOR $($plan.productionContext) WITH TRAFFIC DISABLED"
if ([string]$plan.approval.requiredStatement -ne $requiredStatement) {
    throw 'The initial production approval statement is inconsistent with the plan.'
}
if ($state -eq 'approved') {
    if (
        [string]$plan.approval.approvedBy -ne [string]$plan.approval.owner -or
        [string]$plan.approval.approvalStatement -ne $requiredStatement
    ) {
        throw 'The initial production approval identity or statement is invalid.'
    }
    $approvedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$plan.approval.approvedAtUtc, [ref]$approvedAt)) {
        throw 'The initial production approval timestamp is invalid.'
    }
    $approvedAtUnixSeconds = [long]$plan.approval.approvedAtUnixSeconds
    if ($approvedAtUnixSeconds -ne $approvedAt.ToUnixTimeSeconds()) {
        throw 'The initial production approval timestamp and Unix time do not agree.'
    }
    $approvalInput = "$($plan.integrityDigest)|$($plan.approval.approvedBy)|$approvedAtUnixSeconds|$($plan.approval.approvalStatement)"
    if ((Get-Sha256Text -Text $approvalInput) -ne [string]$plan.approval.approvalDigest) {
        throw 'The initial production approval digest is invalid.'
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
    throw 'A pending initial installation plan contains an inconsistent approval state.'
}

if ($CheckCluster) {
    $CheckCurrentContext = $true
}
if ($CheckCurrentContext) {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl is required to check the production context.'
    }
    $currentContextOutput = @(& kubectl config current-context 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl config current-context failed:`n$($currentContextOutput -join "`n")"
    }
    $currentContext = ($currentContextOutput | Out-String).Trim()
    if (-not [string]::Equals($currentContext, $ExpectedProductionContext, [StringComparison]::Ordinal)) {
        throw "Current Kubernetes context is '$currentContext'; expected '$ExpectedProductionContext'."
    }
}

if ($CheckCluster) {
    $namespace = (Invoke-Kubectl -Arguments @(
        'get', 'namespace', 'shieldward', '--ignore-not-found', '-o', 'name'
    ) | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($namespace)) {
        $existingResources = (Invoke-Kubectl -Arguments @(
            '-n', 'shieldward', 'get',
            'deployments,daemonsets,statefulsets,pods,services,ingresses',
            '-l', 'app.kubernetes.io/name=shieldward',
            '--ignore-not-found', '-o', 'name'
        ) | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingResources)) {
            throw "The target is not an empty initial baseline. Existing ShieldWard resources:`n$existingResources"
        }
    }
    Write-Host 'Initial production cluster preflight passed. No ShieldWard workloads or services exist.'
    Write-Host 'No Secret values were read and no cluster changes were made.'
}

Write-Host "Initial production installation plan validation passed for change $($plan.changeId)."
Write-Host 'This validation is an operator gate, not traffic-routing enforcement.'
