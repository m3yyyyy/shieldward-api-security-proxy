[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StagingEvidencePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProductionContext,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$ChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalOwner,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RemovalAuthority,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficController,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RemovalProcedureReference,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [string]$OutputDirectory = '.shieldward/production-initial',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$semanticVersionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
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

function Assert-OperatorValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [string]$Description,
        [int]$MaximumLength = 128
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f]'
    ) {
        throw "$Description must be a non-empty value of at most $MaximumLength characters without control characters."
    }
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

Assert-OperatorValue -Value $ApprovalOwner -Description 'ApprovalOwner'
Assert-OperatorValue -Value $RemovalAuthority -Description 'RemovalAuthority'
Assert-OperatorValue -Value $TrafficController -Description 'TrafficController'
Assert-OperatorValue -Value $RemovalProcedureReference -Description 'RemovalProcedureReference' -MaximumLength 256
if ($ProductionContext.Length -gt 253 -or $ProductionContext -match '[\x00-\x20]') {
    throw 'ProductionContext must not contain whitespace or control characters.'
}

$resolvedEvidencePath = Resolve-LocalStatePath -Path $StagingEvidencePath -Description 'StagingEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Staging evidence file is missing: $resolvedEvidencePath"
}
$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'installation.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Initial production installation plan already exists: $planPath. Use -Force to replace only this generated plan."
}

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if ([int]$evidence.schemaVersion -ne 1 -or [string]$evidence.environment -ne 'staging') {
    throw 'The supplied evidence is not supported staging evidence.'
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The staging evidence uses unsupported namespace '$($evidence.namespace)'."
}
$releaseVersion = [string]$evidence.releaseVersion
if ($releaseVersion -notmatch $semanticVersionPattern -or [string]$evidence.sourceTag -ne "v$releaseVersion") {
    throw 'The staging evidence release metadata is inconsistent.'
}
$stagingContext = [string]$evidence.kubernetesContext
if ([string]::IsNullOrWhiteSpace($stagingContext)) {
    throw 'The staging evidence does not identify its Kubernetes context.'
}
if ([string]::Equals($stagingContext, $ProductionContext, [StringComparison]::Ordinal)) {
    throw 'ProductionContext must be different from the verified staging context.'
}

$candidateControlPlaneImage = [string]$evidence.images.controlPlane
$candidateEdgeImage = [string]$evidence.images.edge
if ($candidateControlPlaneImage -notmatch "^$([regex]::Escape($controlPlaneRepository))@sha256:[0-9a-f]{64}$") {
    throw "The staging control-plane image is not an approved digest-pinned reference: $candidateControlPlaneImage"
}
if ($candidateEdgeImage -notmatch "^$([regex]::Escape($edgeRepository))@sha256:[0-9a-f]{64}$") {
    throw "The staging Edge image is not an approved digest-pinned reference: $candidateEdgeImage"
}

$phaseNames = @('steadyState', 'controlPlaneOutage', 'recovery')
$policyVersion = ''
foreach ($phaseName in $phaseNames) {
    $phase = $evidence.checks.$phaseName
    if (
        $null -eq $phase -or
        [string]$phase.healthStatus -ne 'ok' -or
        [string]$phase.readyStatus -ne 'ready' -or
        [string]$phase.runtimeVersion -ne $releaseVersion -or
        [int]$phase.defaultDenyStatus -ne 403 -or
        [int]$phase.protectedRouteStatus -ne 401
    ) {
        throw "Staging evidence phase $phaseName did not pass the required acceptance contract."
    }
    $phasePolicyVersion = [string]$phase.policyVersion
    if ($phasePolicyVersion -notmatch $digestPattern) {
        throw "Staging evidence phase $phaseName does not contain a verified policy digest."
    }
    if ([string]::IsNullOrEmpty($policyVersion)) {
        $policyVersion = $phasePolicyVersion
    }
    elseif ($phasePolicyVersion -ne $policyVersion) {
        throw 'The active policy changed during the staging outage or recovery checks.'
    }
}
if ([string]$evidence.checks.controlPlaneRuntimeVersion -ne $releaseVersion) {
    throw 'The control-plane runtime version does not match the staged release.'
}

foreach ($expectedDeployment in @(
    [pscustomobject]@{ Name = 'shieldward-control-plane'; Image = $candidateControlPlaneImage }
    [pscustomobject]@{ Name = 'shieldward-edge'; Image = $candidateEdgeImage }
)) {
    $deployment = @($evidence.deployments) |
        Where-Object { [string]$_.name -eq $expectedDeployment.Name } |
        Select-Object -First 1
    if ($null -eq $deployment) {
        throw "Staging evidence is missing deployment $($expectedDeployment.Name)."
    }
    if ([string]$deployment.image -ne $expectedDeployment.Image) {
        throw "Staging deployment $($expectedDeployment.Name) does not use the candidate image."
    }
    if ([int]$deployment.desiredReplicas -lt 1 -or [int]$deployment.availableReplicas -lt [int]$deployment.desiredReplicas) {
        throw "Staging deployment $($expectedDeployment.Name) was not fully available."
    }
    $available = @($deployment.conditions) |
        Where-Object { [string]$_.type -eq 'Available' -and [string]$_.status -eq 'True' } |
        Select-Object -First 1
    if ($null -eq $available) {
        throw "Staging deployment $($expectedDeployment.Name) has no successful Available condition."
    }
}

$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE INITIAL INSTALL $ChangeId FOR $ProductionContext WITH TRAFFIC DISABLED"

$integrity = [ordered]@{
    stagingEvidenceSha256 = $evidenceHash
    productionContext = $ProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    candidateVersion = $releaseVersion
    candidateControlPlane = $candidateControlPlaneImage
    candidateEdge = $candidateEdgeImage
    trafficState = 'disabled'
    trafficController = $TrafficController
    rollbackMode = 'remove-installation'
    removalAuthority = $RemovalAuthority
    removalProcedureReference = $RemovalProcedureReference
    observationMinutes = $ObservationMinutes
    approvalOwner = $ApprovalOwner
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'initial-installation'
    state = 'pending'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    productionContext = $ProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    observationMinutes = $ObservationMinutes
    stagingEvidence = [ordered]@{
        relativePath = $evidenceRelativePath
        sha256 = $evidenceHash
        context = $stagingContext
        collectedAtUtc = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime().ToString('o')
        policyVersion = $policyVersion
    }
    candidate = [ordered]@{
        version = $releaseVersion
        sourceTag = "v$releaseVersion"
        controlPlaneImage = $candidateControlPlaneImage
        edgeImage = $candidateEdgeImage
    }
    traffic = [ordered]@{
        desiredState = 'disabled'
        controller = $TrafficController
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = 'remove-installation'
        targetState = 'absent'
        authority = $RemovalAuthority
        procedureReference = $RemovalProcedureReference
    }
    approval = [ordered]@{
        status = 'pending'
        owner = $ApprovalOwner
        requiredStatement = $requiredApprovalStatement
        approvedBy = $null
        approvedAtUtc = $null
        approvedAtUnixSeconds = $null
        approvalStatement = $null
        approvalDigest = $null
    }
    safeguards = @(
        'exact-production-context'
        'initial-empty-baseline'
        'traffic-disabled'
        'immutable-candidate-images'
        'verified-staging-evidence'
        'approved-removal-path'
        'bounded-observation-window'
    )
    integrityDigest = $integrityDigest
}

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Pending initial production installation plan created at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'External traffic must remain disabled until a verified production baseline is recorded.'
Write-Host 'No credentials were written and no cluster changes were made.'
