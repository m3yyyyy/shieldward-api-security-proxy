[CmdletBinding()]
param(
    [string]$CanaryEvidencePath = '.shieldward/production-canary/evidence.json',
    [string]$TrafficPlanPath = '',
    [string]$BaselineEvidencePath = '',
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

    [Parameter(Mandatory)]
    [ValidateRange(2, 25)]
    [int]$TargetPercent,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-expansion',
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
$resolvedCanaryEvidencePath = Resolve-LocalStatePath -Path $CanaryEvidencePath -Description 'CanaryEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedCanaryEvidencePath -PathType Leaf)) {
    throw "Production canary evidence is missing: $resolvedCanaryEvidencePath"
}
$evidenceValidationArguments = @{
    EvidencePath = $resolvedCanaryEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
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
if ([string]$canaryEvidence.outcome -ne 'passed') {
    throw "Production canary outcome is '$($canaryEvidence.outcome)'; expansion requires passed evidence."
}
$currentPercent = [int]$canaryEvidence.observation.observedCanaryPercent
if ($TargetPercent -le $currentPercent) {
    throw "TargetPercent must be greater than the observed $currentPercent% canary."
}

$collectedAt = [DateTimeOffset]$canaryEvidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
$observationEndedAt = [DateTimeOffset]$canaryEvidence.observation.endedAtUtc
$observationAge = [DateTimeOffset]::UtcNow - $observationEndedAt.ToUniversalTime()
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt $MaxEvidenceAgeMinutes
) {
    throw "Production canary evidence is outside the approved age of $MaxEvidenceAgeMinutes minutes."
}

$canaryEvidenceHash = (Get-FileHash -LiteralPath $resolvedCanaryEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$canaryEvidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedCanaryEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE EXPANSION TO $TargetPercent% $ChangeId FOR $ExpectedProductionContext RELEASE $($canaryEvidence.candidate.version)"
$integrity = [ordered]@{
    canaryEvidenceSha256 = $canaryEvidenceHash
    canaryEvidenceIntegrityDigest = [string]$canaryEvidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    releaseVersion = [string]$canaryEvidence.candidate.version
    controlPlaneImage = [string]$canaryEvidence.candidate.controlPlaneImage
    edgeImage = [string]$canaryEvidence.candidate.edgeImage
    policyVersion = [string]$canaryEvidence.candidate.policyVersion
    currentTrafficPercent = $currentPercent
    targetTrafficPercent = $TargetPercent
    trafficController = [string]$canaryEvidence.traffic.controller
    controllerChangeReference = [string]$canaryEvidence.externalEvidence.trafficChangeReference
    rollbackMode = [string]$canaryEvidence.rollback.mode
    rollbackAuthority = [string]$canaryEvidence.rollback.authority
    rollbackProcedureReference = [string]$canaryEvidence.rollback.procedureReference
    observationMinutes = $ObservationMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    approvalOwner = $ApprovalOwner
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'initial-traffic-expansion'
    state = 'pending'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    observationMinutes = $ObservationMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    canaryEvidence = [ordered]@{
        relativePath = $canaryEvidenceRelativePath
        sha256 = $canaryEvidenceHash
        integrityDigest = [string]$canaryEvidence.integrityDigest
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        outcome = [string]$canaryEvidence.outcome
    }
    candidate = [ordered]@{
        version = [string]$canaryEvidence.candidate.version
        sourceTag = [string]$canaryEvidence.candidate.sourceTag
        controlPlaneImage = [string]$canaryEvidence.candidate.controlPlaneImage
        edgeImage = [string]$canaryEvidence.candidate.edgeImage
        policyVersion = [string]$canaryEvidence.candidate.policyVersion
    }
    traffic = [ordered]@{
        currentPercent = $currentPercent
        targetPercent = $TargetPercent
        maximumInitialExpansionPercent = 25
        controller = [string]$canaryEvidence.traffic.controller
        controllerChangeReference = [string]$canaryEvidence.externalEvidence.trafficChangeReference
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = [string]$canaryEvidence.rollback.mode
        targetState = [string]$canaryEvidence.rollback.targetState
        authority = [string]$canaryEvidence.rollback.authority
        procedureReference = [string]$canaryEvidence.rollback.procedureReference
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
        'passed-canary-evidence'
        'fresh-observation-evidence'
        'immutable-candidate-images'
        'bounded-first-expansion'
        'external-traffic-enforcement'
        'separate-expansion-approval'
        'disable-before-removal'
        'bounded-observation-window'
    )
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'expansion.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production expansion plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Pending production expansion from $currentPercent% to $TargetPercent% created at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
