[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainmentEvidencePath,

    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$RecoveryChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryOwner,

    [Parameter(Mandatory)]
    [ValidateRange(0, 100)]
    [int]$TargetTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$CurrentTrafficStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'not-required', 'failed', 'unknown')]
    [string]$RemediationStatus,

    [Parameter(Mandatory)]
    [ValidateSet('passed', 'not-required', 'failed', 'unknown')]
    [string]$ReacceptanceStatus,

    [Parameter(Mandatory)]
    [ValidateSet('passed', 'failed', 'unknown')]
    [string]$FunctionalStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$DependencyStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$OperationalStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$CapacityStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'incident', 'unknown')]
    [string]$SecurityStatus,

    [Parameter(Mandatory)]
    [ValidateSet('clear', 'detected', 'unknown')]
    [string]$DriftStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'expiring', 'invalid', 'unknown')]
    [string]$CertificateStatus,

    [Parameter(Mandatory)]
    [ValidateSet('updated', 'missing', 'unknown')]
    [string]$IncidentRecordStatus,

    [Parameter(Mandatory)]
    [ValidateSet('approved', 'pending', 'missing', 'unknown')]
    [string]$RecoveryChangeStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RemediationEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReacceptanceEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryVerificationReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecoveryChangeReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewedBy,

    [ValidateRange(5, 1440)]
    [int]$ApprovalWindowMinutes = 15,

    [ValidateRange(5, 43200)]
    [int]$MaxContainmentAgeMinutes = 10080,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery',
    [switch]$CheckCluster,
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
        [Parameter(Mandatory)][string]$Description,
        [int]$MaximumLength = 256
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most $MaximumLength characters without control characters."
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

Assert-OperatorValue -Value $RecoveryChangeId -Description 'RecoveryChangeId' -MaximumLength 128
Assert-OperatorValue -Value $RecoveryOwner -Description 'RecoveryOwner' -MaximumLength 128
foreach ($reference in @(
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $RemediationEvidenceReference; Description = 'RemediationEvidenceReference' }
    [pscustomobject]@{ Value = $ReacceptanceEvidenceReference; Description = 'ReacceptanceEvidenceReference' }
    [pscustomobject]@{ Value = $RecoveryVerificationReference; Description = 'RecoveryVerificationReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $RecoveryChangeReference; Description = 'RecoveryChangeReference' }
    [pscustomobject]@{ Value = $ReviewedBy; Description = 'ReviewedBy' }
)) {
    Assert-OperatorValue -Value $reference.Value -Description $reference.Description
}

$resolvedContainmentPath = Resolve-LocalStatePath -Path $ContainmentEvidencePath -Description 'ContainmentEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedContainmentPath -PathType Leaf)) {
    throw "Production incident containment evidence is missing: $resolvedContainmentPath"
}
$containmentValidationArguments = @{
    EvidencePath = $resolvedContainmentPath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $containmentValidationArguments.PlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') @containmentValidationArguments 6>$null

$containment = Get-Content -Raw -LiteralPath $resolvedContainmentPath | ConvertFrom-Json
if (
    [string]$containment.outcome -ne 'passed' -or
    [bool]$containment.response.deadlineMet -ne $true -or
    [string]$containment.response.executionStatus -ne 'completed' -or
    [bool]$containment.traffic.matchesPlan -ne $true -or
    [string]$containment.traffic.enforcementStatus -ne 'confirmed' -or
    [string]$containment.verification.workloads -ne 'confirmed' -or
    [string]$containment.verification.incidentRecord -ne 'updated'
) {
    throw 'Incident recovery planning requires passed containment evidence at the exact approved boundary.'
}
if (-not [string]::Equals($RecoveryOwner, [string]$containment.response.authority, [StringComparison]::Ordinal)) {
    throw "RecoveryOwner must exactly match the recorded response authority '$($containment.response.authority)'."
}
if ([string]::Equals($RecoveryChangeId, [string]$containment.changeId, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'RecoveryChangeId must identify a separate recovery change record, not the containment change.'
}

$generatedAt = [DateTimeOffset]::UtcNow
$containmentCollectedAt = [DateTimeOffset]$containment.collectedAtUtc
$containmentAge = $generatedAt - $containmentCollectedAt.ToUniversalTime()
if ($containmentAge.TotalMinutes -lt -5 -or $containmentAge.TotalMinutes -gt $MaxContainmentAgeMinutes) {
    throw "Containment evidence is outside the maximum recovery age of $MaxContainmentAgeMinutes minutes."
}

$currentTrafficPercent = [int]$containment.traffic.observedPercent
$recoveryMode = switch ($currentTrafficPercent) {
    0 {
        if ($TargetTrafficPercent -lt 1 -or $TargetTrafficPercent -gt 10) {
            throw 'Recovery from zero traffic must use an externally enforced canary of 1-10 percent.'
        }
        'bounded-canary-restoration'
    }
    75 {
        if ($TargetTrafficPercent -ne 100) {
            throw 'Recovery from the 75 percent containment cohort must target exactly 100 percent.'
        }
        'restore-full-traffic'
    }
    100 {
        if ($TargetTrafficPercent -ne 100) {
            throw 'Recovery from a 100 percent hold must remain exactly at 100 percent.'
        }
        'resume-at-current-boundary'
    }
    default {
        throw "Unsupported containment boundary '$currentTrafficPercent%'."
    }
}

$remediationRequired = [string]$containment.decision.nextAction -in @(
    'remediate-before-restoration',
    'remediate-and-prepare-recovery'
)
$reacceptanceRequired = [bool]$containment.decision.reacceptanceRequired
$hasFailure = (
    $CurrentTrafficStatus -eq 'failed' -or
    $RemediationStatus -eq 'failed' -or
    $ReacceptanceStatus -eq 'failed' -or
    $FunctionalStatus -eq 'failed' -or
    $DependencyStatus -eq 'degraded' -or
    $OperationalStatus -eq 'degraded' -or
    $CapacityStatus -eq 'degraded' -or
    $SecurityStatus -eq 'incident' -or
    $DriftStatus -eq 'detected' -or
    $CertificateStatus -in @('expiring', 'invalid') -or
    $IncidentRecordStatus -eq 'missing' -or
    $RecoveryChangeStatus -eq 'missing' -or
    ($remediationRequired -and $RemediationStatus -eq 'not-required') -or
    ($reacceptanceRequired -and $ReacceptanceStatus -eq 'not-required')
)
$hasUnknown = @(
    $CurrentTrafficStatus,
    $RemediationStatus,
    $ReacceptanceStatus,
    $FunctionalStatus,
    $DependencyStatus,
    $OperationalStatus,
    $CapacityStatus,
    $SecurityStatus,
    $DriftStatus,
    $CertificateStatus,
    $IncidentRecordStatus,
    $RecoveryChangeStatus
) -contains 'unknown'
if ($RecoveryChangeStatus -eq 'pending') {
    $hasUnknown = $true
}
$readinessOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$state = if ($readinessOutcome -eq 'passed') { 'pending' } else { 'blocked' }
$nextAction = switch ($readinessOutcome) {
    'passed' { 'await-explicit-recovery-approval' }
    'failed' { 'continue-remediation-and-hold-traffic' }
    default { 'collect-current-recovery-evidence-and-hold-traffic' }
}

$expiresAt = $generatedAt.AddMinutes($ApprovalWindowMinutes)
$containmentHash = (Get-FileHash -LiteralPath $resolvedContainmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
$containmentRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedContainmentPath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE PRODUCTION INCIDENT RECOVERY $($containment.incidentId) $RecoveryChangeId FOR $ExpectedProductionContext FROM $currentTrafficPercent% TO $TargetTrafficPercent%"

$integrity = [ordered]@{
    containmentEvidenceSha256 = $containmentHash
    containmentEvidenceIntegrityDigest = [string]$containment.integrityDigest
    responsePlanSha256 = [string]$containment.responsePlan.sha256
    responsePlanIntegrityDigest = [string]$containment.responsePlan.integrityDigest
    responsePlanApprovalDigest = [string]$containment.responsePlan.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$containment.incidentId
    containmentChangeId = [string]$containment.changeId
    recoveryChangeId = $RecoveryChangeId
    generatedAtUtc = $generatedAt.ToUniversalTime().ToString('o')
    expiresAtUtc = $expiresAt.ToUniversalTime().ToString('o')
    approvalWindowMinutes = $ApprovalWindowMinutes
    maxContainmentAgeMinutes = $MaxContainmentAgeMinutes
    releaseVersion = [string]$containment.candidate.version
    sourceTag = [string]$containment.candidate.sourceTag
    controlPlaneImage = [string]$containment.candidate.controlPlaneImage
    edgeImage = [string]$containment.candidate.edgeImage
    policyVersion = [string]$containment.candidate.policyVersion
    trafficController = [string]$containment.traffic.controller
    currentTrafficPercent = $currentTrafficPercent
    targetTrafficPercent = $TargetTrafficPercent
    currentTrafficStatus = $CurrentTrafficStatus
    recoveryMode = $recoveryMode
    remediationRequired = $remediationRequired
    remediationStatus = $RemediationStatus
    reacceptanceRequired = $reacceptanceRequired
    reacceptanceStatus = $ReacceptanceStatus
    functionalStatus = $FunctionalStatus
    dependencyStatus = $DependencyStatus
    operationalStatus = $OperationalStatus
    capacityStatus = $CapacityStatus
    securityStatus = $SecurityStatus
    driftStatus = $DriftStatus
    certificateStatus = $CertificateStatus
    incidentRecordStatus = $IncidentRecordStatus
    recoveryChangeStatus = $RecoveryChangeStatus
    trafficStateReference = $TrafficStateReference
    remediationEvidenceReference = $RemediationEvidenceReference
    reacceptanceEvidenceReference = $ReacceptanceEvidenceReference
    recoveryVerificationReference = $RecoveryVerificationReference
    incidentRecordReference = $IncidentRecordReference
    recoveryChangeReference = $RecoveryChangeReference
    recoveryOwner = $RecoveryOwner
    reviewedBy = $ReviewedBy
    readinessOutcome = $readinessOutcome
    nextAction = $nextAction
    afterApprovalAction = 'execute-approved-recovery-externally'
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'production-incident-recovery'
    state = $state
    generatedAtUtc = $generatedAt.ToString('o')
    expiresAtUtc = $expiresAt.ToString('o')
    approvalWindowMinutes = $ApprovalWindowMinutes
    maxContainmentAgeMinutes = $MaxContainmentAgeMinutes
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$containment.incidentId
    containmentChangeId = [string]$containment.changeId
    recoveryChangeId = $RecoveryChangeId
    containmentEvidence = [ordered]@{
        relativePath = $containmentRelativePath
        sha256 = $containmentHash
        integrityDigest = [string]$containment.integrityDigest
        collectedAtUtc = $containmentCollectedAt.ToUniversalTime().ToString('o')
        outcome = [string]$containment.outcome
        responsePlanSha256 = [string]$containment.responsePlan.sha256
        responsePlanIntegrityDigest = [string]$containment.responsePlan.integrityDigest
        responsePlanApprovalDigest = [string]$containment.responsePlan.approvalDigest
    }
    candidate = [ordered]@{
        version = [string]$containment.candidate.version
        sourceTag = [string]$containment.candidate.sourceTag
        controlPlaneImage = [string]$containment.candidate.controlPlaneImage
        edgeImage = [string]$containment.candidate.edgeImage
        policyVersion = [string]$containment.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$containment.traffic.controller
        currentPercent = $currentTrafficPercent
        targetPercent = $TargetTrafficPercent
        currentStatus = $CurrentTrafficStatus
        externallyConfirmed = $CurrentTrafficStatus -eq 'confirmed'
        externalExecutionRequired = $true
    }
    readiness = [ordered]@{
        outcome = $readinessOutcome
        remediationRequired = $remediationRequired
        remediationStatus = $RemediationStatus
        reacceptanceRequired = $reacceptanceRequired
        reacceptanceStatus = $ReacceptanceStatus
        functionalStatus = $FunctionalStatus
        dependencyStatus = $DependencyStatus
        operationalStatus = $OperationalStatus
        capacityStatus = $CapacityStatus
        securityStatus = $SecurityStatus
        driftStatus = $DriftStatus
        certificateStatus = $CertificateStatus
        incidentRecordStatus = $IncidentRecordStatus
        recoveryChangeStatus = $RecoveryChangeStatus
    }
    externalEvidence = [ordered]@{
        trafficStateReference = $TrafficStateReference
        remediationEvidenceReference = $RemediationEvidenceReference
        reacceptanceEvidenceReference = $ReacceptanceEvidenceReference
        recoveryVerificationReference = $RecoveryVerificationReference
        incidentRecordReference = $IncidentRecordReference
        recoveryChangeReference = $RecoveryChangeReference
        reviewedBy = $ReviewedBy
    }
    recovery = [ordered]@{
        mode = $recoveryMode
        owner = $RecoveryOwner
        procedureReference = [string]$containment.response.procedureReference
        executionState = 'not-started'
        externalIncidentSystemRequired = $true
        externalTrafficControllerRequired = $true
    }
    rollback = [ordered]@{
        targetPercent = $currentTrafficPercent
        emergencyTargetPercent = 0
        authority = $RecoveryOwner
        procedureReference = [string]$containment.response.procedureReference
    }
    decision = [ordered]@{
        nextAction = $nextAction
        afterApprovalAction = 'execute-approved-recovery-externally'
        holdTrafficAtPercent = $currentTrafficPercent
    }
    approval = [ordered]@{
        status = if ($state -eq 'pending') { 'pending' } else { 'blocked' }
        owner = $RecoveryOwner
        requiredStatement = $requiredApprovalStatement
        approvedBy = $null
        approvedAtUtc = $null
        approvedAtUnixSeconds = $null
        approvalStatement = $null
        approvalDigest = $null
    }
    safeguards = @(
        'passed-immutable-containment-evidence'
        'separate-recovery-change-record'
        'current-contained-traffic-confirmation'
        'explicit-remediation-and-reacceptance-status'
        'healthy-recovery-verification'
        'bounded-zero-to-canary-restoration'
        'exact-seventy-five-to-full-restoration'
        'explicit-recovery-approval'
        'restore-only-through-external-controller'
        'rollback-to-contained-boundary'
        'no-automatic-production-mutation'
        'preserve-audit-evidence'
    )
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'recovery.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production incident recovery plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production incident recovery plan recorded at $planPath with readiness '$readinessOutcome'."
Write-Host "Recovery boundary: $currentTrafficPercent% to $TargetTrafficPercent%; state: $state"
if ($state -eq 'pending') {
    Write-Host "Required approval statement: $requiredApprovalStatement"
}
else {
    Write-Warning 'Recovery is blocked. Hold the current traffic boundary and preserve this evidence.'
}
Write-Host 'No cluster or traffic changes were made.'
