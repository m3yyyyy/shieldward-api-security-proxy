[CmdletBinding()]
param(
    [string]$ClosurePlanPath = '.shieldward/production-incident-recovery-closure/closure.json',
    [string]$FinalExpansionEvidencePath = '',
    [string]$FinalExpansionPlanPath = '',
    [string]$SecondExpansionEvidencePath = '',
    [string]$SecondExpansionPlanPath = '',
    [string]$ProgressiveEvidencePath = '',
    [string]$ProgressivePlanPath = '',
    [string]$ExpansionEvidencePath = '',
    [string]$ExpansionPlanPath = '',
    [string]$RecoveryEvidencePath = '',
    [string]$RecoveryPlanPath = '',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ClosedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(100, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$TrafficEnforcementStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'failed', 'unknown')]
    [string]$ClosureExecutionStatus,

    [Parameter(Mandatory)]
    [ValidateSet('closed', 'open', 'unknown')]
    [string]$IncidentClosureStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'failed', 'unknown')]
    [string]$ClosureChangeRecordStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$PostClosureMonitoringStatus,

    [Parameter(Mandatory)]
    [ValidateSet('retained', 'missing', 'unknown')]
    [string]$RollbackRetentionStatus,

    [Parameter(Mandatory)]
    [ValidateSet('complete', 'incomplete', 'unknown')]
    [string]$AuditEvidenceStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClosureGateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentClosureReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClosureChangeRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PostClosureMonitoringReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RollbackRetentionReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AuditEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectedBy,

    [ValidateRange(5, 1440)]
    [int]$MaxClosureAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-recovery-closure-evidence',
    [switch]$CheckCluster,
    [switch]$Force,
    [string]$ReferenceTimeUtc = ''
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

function Assert-EvidenceReference {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Description
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 256 -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most 256 characters without control characters."
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

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

foreach ($reference in @(
    [pscustomobject]@{ Value = $ClosureGateReference; Description = 'ClosureGateReference' }
    [pscustomobject]@{ Value = $IncidentClosureReference; Description = 'IncidentClosureReference' }
    [pscustomobject]@{ Value = $ClosureChangeRecordReference; Description = 'ClosureChangeRecordReference' }
    [pscustomobject]@{ Value = $PostClosureMonitoringReference; Description = 'PostClosureMonitoringReference' }
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $RollbackRetentionReference; Description = 'RollbackRetentionReference' }
    [pscustomobject]@{ Value = $AuditEvidenceReference; Description = 'AuditEvidenceReference' }
    [pscustomobject]@{ Value = $CollectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $ClosurePlanPath -Description 'ClosurePlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery closure plan is missing: $resolvedPlanPath"
}
$planValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'FinalExpansionEvidencePath'; Value = $FinalExpansionEvidencePath }
    [pscustomobject]@{ Name = 'FinalExpansionPlanPath'; Value = $FinalExpansionPlanPath }
    [pscustomobject]@{ Name = 'SecondExpansionEvidencePath'; Value = $SecondExpansionEvidencePath }
    [pscustomobject]@{ Name = 'SecondExpansionPlanPath'; Value = $SecondExpansionPlanPath }
    [pscustomobject]@{ Name = 'ProgressiveEvidencePath'; Value = $ProgressiveEvidencePath }
    [pscustomobject]@{ Name = 'ProgressivePlanPath'; Value = $ProgressivePlanPath }
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'ExpansionPlanPath'; Value = $ExpansionPlanPath }
    [pscustomobject]@{ Name = 'RecoveryEvidencePath'; Value = $RecoveryEvidencePath }
    [pscustomobject]@{ Name = 'RecoveryPlanPath'; Value = $RecoveryPlanPath }
    [pscustomobject]@{ Name = 'ContainmentEvidencePath'; Value = $ContainmentEvidencePath }
    [pscustomobject]@{ Name = 'ResponsePlanPath'; Value = $ResponsePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $planValidationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $planValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-plan.ps1') @planValidationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$expiresAt = ([DateTimeOffset]$plan.expiresAtUtc).ToUniversalTime()
$closedAt = $ClosedAtUtc.ToUniversalTime()
$closureAge = $referenceNow - $closedAt
if (
    $closedAt -lt $approvedAt -or
    $closedAt -gt $expiresAt -or
    $closureAge.TotalMinutes -lt -5 -or
    $closureAge.TotalMinutes -gt $MaxClosureAgeMinutes
) {
    throw "ClosedAtUtc must follow approval, precede plan expiry, and be within $MaxClosureAgeMinutes minutes of the current reference time."
}

if (
    [int]$plan.traffic.currentPercent -ne 100 -or
    [int]$plan.traffic.holdPercent -ne 100 -or
    [int]$plan.traffic.trafficMutationPercentagePoints -ne 0 -or
    [int]$plan.rollback.targetPercent -ne 75 -or
    [int]$plan.rollback.emergencyTargetPercent -ne 0 -or
    [string]$plan.observation.reacceptance -ne 'passed' -or
    [string]$plan.observation.closureChange -ne 'approved' -or
    [string]$plan.decision.afterApprovalAction -ne 'close-recovery-incident-externally-after-independent-review'
) {
    throw 'Closure evidence requires an approved no-mutation plan at 100 percent with passed re-acceptance and rollback to 75 or emergency zero.'
}

$trafficMatchesPlan = $ObservedTrafficPercent -eq [int]$plan.traffic.holdPercent
$hasFailure = (
    $TrafficEnforcementStatus -eq 'failed' -or
    $ClosureExecutionStatus -eq 'failed' -or
    $IncidentClosureStatus -eq 'open' -or
    $ClosureChangeRecordStatus -eq 'failed' -or
    $PostClosureMonitoringStatus -eq 'degraded' -or
    $RollbackRetentionStatus -eq 'missing' -or
    $AuditEvidenceStatus -eq 'incomplete' -or
    -not $trafficMatchesPlan
)
$hasUnknown = @(
    $TrafficEnforcementStatus,
    $ClosureExecutionStatus,
    $IncidentClosureStatus,
    $ClosureChangeRecordStatus,
    $PostClosureMonitoringStatus,
    $RollbackRetentionStatus,
    $AuditEvidenceStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$closureRecorded = (
    $ClosureExecutionStatus -eq 'completed' -and
    $IncidentClosureStatus -eq 'closed' -and
    $ClosureChangeRecordStatus -eq 'completed'
)
$nextAction = switch ($outcome) {
    'passed' { 'begin-post-incident-assurance-and-retrospective' }
    'failed' { 'reopen-or-escalate-incident-and-preserve-rollback' }
    default { 'treat-incident-as-open-and-collect-closure-evidence' }
}

$collectedAt = $referenceNow
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$integrity = [ordered]@{
    closurePlanSha256 = $planHash
    closurePlanIntegrityDigest = [string]$plan.integrityDigest
    closurePlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    finalExpansionChangeId = [string]$plan.finalExpansionChangeId
    closureChangeId = [string]$plan.closureChangeId
    releaseVersion = [string]$plan.candidate.version
    sourceTag = [string]$plan.candidate.sourceTag
    controlPlaneImage = [string]$plan.candidate.controlPlaneImage
    edgeImage = [string]$plan.candidate.edgeImage
    policyVersion = [string]$plan.candidate.policyVersion
    expectedTrafficPercent = [int]$plan.traffic.holdPercent
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = $TrafficEnforcementStatus
    closureExecutionStatus = $ClosureExecutionStatus
    incidentClosureStatus = $IncidentClosureStatus
    closureChangeRecordStatus = $ClosureChangeRecordStatus
    postClosureMonitoringStatus = $PostClosureMonitoringStatus
    rollbackRetentionStatus = $RollbackRetentionStatus
    auditEvidenceStatus = $AuditEvidenceStatus
    rollbackTargetPercent = [int]$plan.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
    rollbackAuthority = [string]$plan.rollback.authority
    rollbackProcedureReference = [string]$plan.rollback.procedureReference
    closedAtUtc = $closedAt.ToString('o')
    maxClosureAgeMinutes = $MaxClosureAgeMinutes
    closureGateReference = $ClosureGateReference
    incidentClosureReference = $IncidentClosureReference
    closureChangeRecordReference = $ClosureChangeRecordReference
    postClosureMonitoringReference = $PostClosureMonitoringReference
    trafficStateReference = $TrafficStateReference
    rollbackRetentionReference = $RollbackRetentionReference
    auditEvidenceReference = $AuditEvidenceReference
    collectedBy = $CollectedBy
    closureRecorded = $closureRecorded
    outcome = $outcome
    nextAction = $nextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'incident-recovery-closure-execution'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    containmentChangeId = [string]$plan.containmentChangeId
    recoveryChangeId = [string]$plan.recoveryChangeId
    expansionChangeId = [string]$plan.expansionChangeId
    progressiveChangeId = [string]$plan.progressiveChangeId
    finalExpansionChangeId = [string]$plan.finalExpansionChangeId
    closureChangeId = [string]$plan.closureChangeId
    maxClosureAgeMinutes = $MaxClosureAgeMinutes
    closurePlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        approvedAtUtc = $approvedAt.ToString('o')
        expiresAtUtc = $expiresAt.ToString('o')
        state = [string]$plan.state
    }
    candidate = [ordered]@{
        version = [string]$plan.candidate.version
        sourceTag = [string]$plan.candidate.sourceTag
        controlPlaneImage = [string]$plan.candidate.controlPlaneImage
        edgeImage = [string]$plan.candidate.edgeImage
        policyVersion = [string]$plan.candidate.policyVersion
    }
    execution = [ordered]@{
        status = $ClosureExecutionStatus
        closedAtUtc = $closedAt.ToString('o')
        authoritativeExternalSystemRequired = $true
        performedByRepository = $false
    }
    closure = [ordered]@{
        incidentStatus = $IncidentClosureStatus
        changeRecordStatus = $ClosureChangeRecordStatus
        recorded = $closureRecorded
    }
    traffic = [ordered]@{
        expectedPercent = [int]$plan.traffic.holdPercent
        observedPercent = $ObservedTrafficPercent
        matchesPlan = $trafficMatchesPlan
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
        mutationPercentagePoints = 0
    }
    verification = [ordered]@{
        postClosureMonitoring = $PostClosureMonitoringStatus
        rollbackRetention = $RollbackRetentionStatus
        auditEvidence = $AuditEvidenceStatus
    }
    externalEvidence = [ordered]@{
        closureGateReference = $ClosureGateReference
        incidentClosureReference = $IncidentClosureReference
        closureChangeRecordReference = $ClosureChangeRecordReference
        postClosureMonitoringReference = $PostClosureMonitoringReference
        trafficStateReference = $TrafficStateReference
        rollbackRetentionReference = $RollbackRetentionReference
        auditEvidenceReference = $AuditEvidenceReference
        collectedBy = $CollectedBy
    }
    rollback = [ordered]@{
        mode = [string]$plan.rollback.mode
        targetPercent = [int]$plan.rollback.targetPercent
        emergencyTargetPercent = [int]$plan.rollback.emergencyTargetPercent
        authority = [string]$plan.rollback.authority
        procedureReference = [string]$plan.rollback.procedureReference
        retentionStatus = $RollbackRetentionStatus
    }
    decision = [ordered]@{
        closureRecorded = $closureRecorded
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'closure-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production incident recovery closure evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production recovery incident-closure evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Recorded external incident status: $IncidentClosureStatus; next action: $nextAction"
Write-Host 'No cluster, traffic, change-record, or incident-system changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Recovery incident closure is not proven. Treat the incident as open, preserve rollback, and collect authoritative evidence.'
}
