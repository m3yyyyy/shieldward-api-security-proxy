[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaselineEvidencePath,

    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$ChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalOwner,

    [ValidateRange(1, 10)]
    [int]$CanaryPercent = 1,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxBaselineAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-traffic',
    [switch]$Force
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

Assert-OperatorValue -Value $ApprovalOwner -Description 'ApprovalOwner'
$resolvedBaselinePath = Resolve-LocalStatePath -Path $BaselineEvidencePath -Description 'BaselineEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Production baseline evidence is missing: $resolvedBaselinePath"
}

$baselineValidationArguments = @{
    BaselineEvidencePath = $resolvedBaselinePath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($InitialPlanPath)) {
    $baselineValidationArguments.InitialPlanPath = $InitialPlanPath
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $baselineValidationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-production-baseline-evidence.ps1') @baselineValidationArguments | Out-Null
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json

$collectedAt = [DateTimeOffset]$baseline.collectedAtUtc
$baselineAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
if ($baselineAge.TotalMinutes -lt -5 -or $baselineAge.TotalMinutes -gt $MaxBaselineAgeMinutes) {
    throw "Production baseline evidence is outside the approved age of $MaxBaselineAgeMinutes minutes."
}

$resolvedInitialPlanPath = if ([string]::IsNullOrWhiteSpace($InitialPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$baseline.initialPlan.relativePath) -Description 'Recorded initial plan path'
}
else {
    Resolve-LocalStatePath -Path $InitialPlanPath -Description 'InitialPlanPath'
}
$initialPlan = Get-Content -Raw -LiteralPath $resolvedInitialPlanPath | ConvertFrom-Json
$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'activation.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production traffic activation plan already exists: $planPath. Use -Force to replace only this generated plan."
}

$baselineHash = (Get-FileHash -LiteralPath $resolvedBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBaselinePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE $CanaryPercent% CANARY $ChangeId FOR $ExpectedProductionContext RELEASE $($baseline.releaseVersion)"
$integrity = [ordered]@{
    baselineEvidenceSha256 = $baselineHash
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    releaseVersion = [string]$baseline.releaseVersion
    controlPlaneImage = [string]$baseline.images.controlPlane
    edgeImage = [string]$baseline.images.edge
    currentTrafficState = 'disabled'
    requestedTrafficState = 'canary'
    canaryPercent = $CanaryPercent
    trafficController = [string]$baseline.traffic.controller
    rollbackMode = 'disable-traffic-and-remove-installation'
    removalAuthority = [string]$initialPlan.rollback.authority
    removalProcedureReference = [string]$initialPlan.rollback.procedureReference
    observationMinutes = $ObservationMinutes
    maxBaselineAgeMinutes = $MaxBaselineAgeMinutes
    approvalOwner = $ApprovalOwner
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'initial-traffic-activation'
    state = 'pending'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    observationMinutes = $ObservationMinutes
    maxBaselineAgeMinutes = $MaxBaselineAgeMinutes
    baselineEvidence = [ordered]@{
        relativePath = $baselineRelativePath
        sha256 = $baselineHash
        collectedAtUtc = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime().ToString('o')
        integrityDigest = [string]$baseline.integrityDigest
    }
    candidate = [ordered]@{
        version = [string]$baseline.releaseVersion
        sourceTag = [string]$baseline.sourceTag
        controlPlaneImage = [string]$baseline.images.controlPlane
        edgeImage = [string]$baseline.images.edge
        policyVersion = [string]$baseline.acceptance.edge.policyVersion
    }
    traffic = [ordered]@{
        currentState = 'disabled'
        requestedState = 'canary'
        canaryPercent = $CanaryPercent
        controller = [string]$baseline.traffic.controller
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = 'disable-traffic-and-remove-installation'
        targetState = 'absent'
        authority = [string]$initialPlan.rollback.authority
        procedureReference = [string]$initialPlan.rollback.procedureReference
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
        'fresh-traffic-disabled-baseline'
        'immutable-candidate-images'
        'bounded-initial-canary'
        'external-traffic-enforcement'
        'disable-before-removal'
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

Write-Host "Pending $CanaryPercent% production canary plan created at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
