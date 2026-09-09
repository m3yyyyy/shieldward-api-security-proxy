[CmdletBinding()]
param(
    [string]$ExpansionEvidencePath = '.shieldward/production-expansion-evidence/evidence.json',
    [string]$ExpansionPlanPath = '',
    [string]$CanaryEvidencePath = '',
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
    [ValidateRange(3, 50)]
    [int]$TargetPercent,

    [ValidateRange(5, 1440)]
    [int]$ObservationMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-progressive',
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
$resolvedEvidencePath = Resolve-LocalStatePath -Path $ExpansionEvidencePath -Description 'ExpansionEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production first-expansion evidence is missing: $resolvedEvidencePath"
}
$evidenceValidationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
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
$expansionEvidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if ([string]$expansionEvidence.outcome -ne 'passed') {
    throw "Production first-expansion outcome is '$($expansionEvidence.outcome)'; progressive expansion requires passed evidence."
}

$currentPercent = [int]$expansionEvidence.observation.observedTrafficPercent
if (
    $currentPercent -lt 2 -or
    $currentPercent -gt 25 -or
    $TargetPercent -le $currentPercent -or
    ($TargetPercent - $currentPercent) -gt 25
) {
    throw "TargetPercent must increase the observed $currentPercent% cohort by at most 25 percentage points."
}

$collectedAt = [DateTimeOffset]$expansionEvidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
$observationEndedAt = [DateTimeOffset]$expansionEvidence.observation.endedAtUtc
$observationAge = [DateTimeOffset]::UtcNow - $observationEndedAt.ToUniversalTime()
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $observationAge.TotalMinutes -lt -5 -or
    $observationAge.TotalMinutes -gt $MaxEvidenceAgeMinutes
) {
    throw "Production first-expansion evidence is outside the approved age of $MaxEvidenceAgeMinutes minutes."
}

$expansionEvidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$expansionEvidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE EXPANSION TO $TargetPercent% $ChangeId FOR $ExpectedProductionContext RELEASE $($expansionEvidence.candidate.version)"
$integrity = [ordered]@{
    expansionEvidenceSha256 = $expansionEvidenceHash
    expansionEvidenceIntegrityDigest = [string]$expansionEvidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    releaseVersion = [string]$expansionEvidence.candidate.version
    controlPlaneImage = [string]$expansionEvidence.candidate.controlPlaneImage
    edgeImage = [string]$expansionEvidence.candidate.edgeImage
    policyVersion = [string]$expansionEvidence.candidate.policyVersion
    currentTrafficPercent = $currentPercent
    targetTrafficPercent = $TargetPercent
    maximumTargetPercent = 50
    maximumStepPercentagePoints = 25
    trafficController = [string]$expansionEvidence.traffic.controller
    controllerChangeReference = [string]$expansionEvidence.externalEvidence.trafficChangeReference
    rollbackMode = 'restore-previous-cohort-or-disable-and-remove'
    rollbackTargetPercent = $currentPercent
    rollbackEmergencyTargetPercent = 0
    rollbackAuthority = [string]$expansionEvidence.rollback.authority
    rollbackProcedureReference = [string]$expansionEvidence.rollback.procedureReference
    observationMinutes = $ObservationMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    approvalOwner = $ApprovalOwner
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'progressive-traffic-expansion'
    state = 'pending'
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    changeId = $ChangeId
    observationMinutes = $ObservationMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    expansionEvidence = [ordered]@{
        relativePath = $expansionEvidenceRelativePath
        sha256 = $expansionEvidenceHash
        integrityDigest = [string]$expansionEvidence.integrityDigest
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        observationEndedAtUtc = $observationEndedAt.ToUniversalTime().ToString('o')
        outcome = [string]$expansionEvidence.outcome
    }
    candidate = [ordered]@{
        version = [string]$expansionEvidence.candidate.version
        sourceTag = [string]$expansionEvidence.candidate.sourceTag
        controlPlaneImage = [string]$expansionEvidence.candidate.controlPlaneImage
        edgeImage = [string]$expansionEvidence.candidate.edgeImage
        policyVersion = [string]$expansionEvidence.candidate.policyVersion
    }
    traffic = [ordered]@{
        currentPercent = $currentPercent
        targetPercent = $TargetPercent
        maximumTargetPercent = 50
        maximumStepPercentagePoints = 25
        controller = [string]$expansionEvidence.traffic.controller
        controllerChangeReference = [string]$expansionEvidence.externalEvidence.trafficChangeReference
        externalEnforcementRequired = $true
    }
    rollback = [ordered]@{
        mode = 'restore-previous-cohort-or-disable-and-remove'
        targetPercent = $currentPercent
        emergencyTargetPercent = 0
        authority = [string]$expansionEvidence.rollback.authority
        procedureReference = [string]$expansionEvidence.rollback.procedureReference
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
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'expansion.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production progressive expansion plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Pending production progressive expansion from $currentPercent% to $TargetPercent% created at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
