[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClosureEvidencePath,

    [string]$ClosurePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [DateTimeOffset]$AssessedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(100, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$TrafficEnforcementStatus,

    [Parameter(Mandatory)]
    [ValidateSet('closed', 'reopened', 'unknown')]
    [string]$CurrentIncidentStatus,

    [Parameter(Mandatory)]
    [ValidateSet('healthy', 'degraded', 'unknown')]
    [string]$SustainedHealthStatus,

    [Parameter(Mandatory)]
    [ValidateSet('within-budget', 'breached', 'unknown')]
    [string]$ErrorBudgetStatus,

    [Parameter(Mandatory)]
    [ValidateSet('complete', 'failed', 'unknown')]
    [string]$SecurityReviewStatus,

    [Parameter(Mandatory)]
    [ValidateSet('complete', 'incomplete', 'unknown')]
    [string]$RootCauseAnalysisStatus,

    [Parameter(Mandatory)]
    [ValidateSet('tracked', 'incomplete', 'unknown')]
    [string]$CorrectiveActionsStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'incomplete', 'unknown')]
    [string]$RetrospectiveStatus,

    [Parameter(Mandatory)]
    [ValidateSet('retained', 'missing', 'unknown')]
    [string]$RollbackRetentionStatus,

    [Parameter(Mandatory)]
    [ValidateSet('complete', 'incomplete', 'unknown')]
    [string]$AuditEvidenceStatus,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClosureEvidenceGateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$IncidentRecordReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AssuranceWindowReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ErrorBudgetReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SecurityReviewReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RootCauseAnalysisReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CorrectiveActionsReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RetrospectiveReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TrafficStateReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RollbackRetentionReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuditEvidenceReference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CollectedBy,

    [ValidateRange(1, 720)]
    [int]$MinimumAssuranceWindowHours = 24,

    [ValidateRange(1, 2160)]
    [int]$MaxClosureEvidenceAgeHours = 720,

    [ValidateRange(5, 1440)]
    [int]$MaxAssessmentAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-post-incident-assurance',
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
    [pscustomobject]@{ Value = $ClosureEvidenceGateReference; Description = 'ClosureEvidenceGateReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $AssuranceWindowReference; Description = 'AssuranceWindowReference' }
    [pscustomobject]@{ Value = $ErrorBudgetReference; Description = 'ErrorBudgetReference' }
    [pscustomobject]@{ Value = $SecurityReviewReference; Description = 'SecurityReviewReference' }
    [pscustomobject]@{ Value = $RootCauseAnalysisReference; Description = 'RootCauseAnalysisReference' }
    [pscustomobject]@{ Value = $CorrectiveActionsReference; Description = 'CorrectiveActionsReference' }
    [pscustomobject]@{ Value = $RetrospectiveReference; Description = 'RetrospectiveReference' }
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $RollbackRetentionReference; Description = 'RollbackRetentionReference' }
    [pscustomobject]@{ Value = $AuditEvidenceReference; Description = 'AuditEvidenceReference' }
    [pscustomobject]@{ Value = $CollectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedClosureEvidencePath = Resolve-LocalStatePath -Path $ClosureEvidencePath -Description 'ClosureEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedClosureEvidencePath -PathType Leaf)) {
    throw "Production incident recovery closure evidence is missing: $resolvedClosureEvidencePath"
}

$closureValidationArguments = @{
    EvidencePath = $resolvedClosureEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ClosurePlanPath)) {
    $closureValidationArguments.ClosurePlanPath = $ClosurePlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $closureValidationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence.ps1') @closureValidationArguments 6>$null

$closureEvidence = Get-Content -Raw -LiteralPath $resolvedClosureEvidencePath | ConvertFrom-Json
if (
    [string]$closureEvidence.outcome -ne 'passed' -or
    [bool]$closureEvidence.closure.recorded -ne $true -or
    [string]$closureEvidence.closure.incidentStatus -ne 'closed' -or
    [string]$closureEvidence.closure.changeRecordStatus -ne 'completed' -or
    [string]$closureEvidence.decision.nextAction -ne 'begin-post-incident-assurance-and-retrospective' -or
    [int]$closureEvidence.traffic.observedPercent -ne 100 -or
    [int]$closureEvidence.traffic.mutationPercentagePoints -ne 0 -or
    [string]$closureEvidence.verification.rollbackRetention -ne 'retained'
) {
    throw 'Post-incident assurance requires passed authoritative incident-closure execution evidence.'
}

$assessedAt = $AssessedAtUtc.ToUniversalTime()
$closedAt = ([DateTimeOffset]$closureEvidence.execution.closedAtUtc).ToUniversalTime()
$closureCollectedAt = ([DateTimeOffset]$closureEvidence.collectedAtUtc).ToUniversalTime()
$assuranceWindow = $assessedAt - $closedAt
$closureEvidenceAge = $referenceNow - $closureCollectedAt
$assessmentAge = $referenceNow - $assessedAt
if (
    $assuranceWindow.TotalHours -lt $MinimumAssuranceWindowHours -or
    $closureEvidenceAge.TotalHours -lt -1 -or
    $closureEvidenceAge.TotalHours -gt $MaxClosureEvidenceAgeHours -or
    $assessmentAge.TotalMinutes -lt -5 -or
    $assessmentAge.TotalMinutes -gt $MaxAssessmentAgeMinutes
) {
    throw 'Post-incident assessment must follow the minimum assurance window and use current, freshness-bounded closure and assessment evidence.'
}

$trafficMatchesClosure = $ObservedTrafficPercent -eq [int]$closureEvidence.traffic.observedPercent
$hasFailure = (
    $TrafficEnforcementStatus -eq 'failed' -or
    $CurrentIncidentStatus -eq 'reopened' -or
    $SustainedHealthStatus -eq 'degraded' -or
    $ErrorBudgetStatus -eq 'breached' -or
    $SecurityReviewStatus -eq 'failed' -or
    $RootCauseAnalysisStatus -eq 'incomplete' -or
    $CorrectiveActionsStatus -eq 'incomplete' -or
    $RetrospectiveStatus -eq 'incomplete' -or
    $RollbackRetentionStatus -eq 'missing' -or
    $AuditEvidenceStatus -eq 'incomplete' -or
    -not $trafficMatchesClosure
)
$hasUnknown = @(
    $TrafficEnforcementStatus,
    $CurrentIncidentStatus,
    $SustainedHealthStatus,
    $ErrorBudgetStatus,
    $SecurityReviewStatus,
    $RootCauseAnalysisStatus,
    $CorrectiveActionsStatus,
    $RetrospectiveStatus,
    $RollbackRetentionStatus,
    $AuditEvidenceStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$retrospectiveRecorded = (
    $RootCauseAnalysisStatus -eq 'complete' -and
    $CorrectiveActionsStatus -eq 'tracked' -and
    $RetrospectiveStatus -eq 'completed'
)
$nextAction = switch ($outcome) {
    'passed' { 'resume-continuous-production-assurance' }
    'failed' { 'reopen-or-escalate-incident-and-preserve-rollback' }
    default { 'treat-assurance-as-incomplete-and-collect-evidence' }
}

$collectedAt = $referenceNow
$closureHash = (Get-FileHash -LiteralPath $resolvedClosureEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$closureRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedClosureEvidencePath).Replace('\', '/')
$integrity = [ordered]@{
    closureEvidenceSha256 = $closureHash
    closureEvidenceIntegrityDigest = [string]$closureEvidence.integrityDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$closureEvidence.incidentId
    closureChangeId = [string]$closureEvidence.closureChangeId
    releaseVersion = [string]$closureEvidence.candidate.version
    sourceTag = [string]$closureEvidence.candidate.sourceTag
    controlPlaneImage = [string]$closureEvidence.candidate.controlPlaneImage
    edgeImage = [string]$closureEvidence.candidate.edgeImage
    policyVersion = [string]$closureEvidence.candidate.policyVersion
    closedAtUtc = $closedAt.ToString('o')
    closureEvidenceCollectedAtUtc = $closureCollectedAt.ToString('o')
    assessedAtUtc = $assessedAt.ToString('o')
    minimumAssuranceWindowHours = $MinimumAssuranceWindowHours
    maxClosureEvidenceAgeHours = $MaxClosureEvidenceAgeHours
    maxAssessmentAgeMinutes = $MaxAssessmentAgeMinutes
    currentIncidentStatus = $CurrentIncidentStatus
    expectedTrafficPercent = 100
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesClosure = $trafficMatchesClosure
    trafficEnforcementStatus = $TrafficEnforcementStatus
    sustainedHealthStatus = $SustainedHealthStatus
    errorBudgetStatus = $ErrorBudgetStatus
    securityReviewStatus = $SecurityReviewStatus
    rootCauseAnalysisStatus = $RootCauseAnalysisStatus
    correctiveActionsStatus = $CorrectiveActionsStatus
    retrospectiveStatus = $RetrospectiveStatus
    rollbackRetentionStatus = $RollbackRetentionStatus
    auditEvidenceStatus = $AuditEvidenceStatus
    rollbackTargetPercent = [int]$closureEvidence.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$closureEvidence.rollback.emergencyTargetPercent
    closureEvidenceGateReference = $ClosureEvidenceGateReference
    incidentRecordReference = $IncidentRecordReference
    assuranceWindowReference = $AssuranceWindowReference
    errorBudgetReference = $ErrorBudgetReference
    securityReviewReference = $SecurityReviewReference
    rootCauseAnalysisReference = $RootCauseAnalysisReference
    correctiveActionsReference = $CorrectiveActionsReference
    retrospectiveReference = $RetrospectiveReference
    trafficStateReference = $TrafficStateReference
    rollbackRetentionReference = $RollbackRetentionReference
    auditEvidenceReference = $AuditEvidenceReference
    collectedBy = $CollectedBy
    retrospectiveRecorded = $retrospectiveRecorded
    outcome = $outcome
    nextAction = $nextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'post-incident-assurance-and-retrospective'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$closureEvidence.incidentId
    closureChangeId = [string]$closureEvidence.closureChangeId
    closureEvidence = [ordered]@{
        relativePath = $closureRelativePath
        sha256 = $closureHash
        integrityDigest = [string]$closureEvidence.integrityDigest
        collectedAtUtc = $closureCollectedAt.ToString('o')
        closedAtUtc = $closedAt.ToString('o')
        closureRecorded = $true
    }
    candidate = [ordered]@{
        version = [string]$closureEvidence.candidate.version
        sourceTag = [string]$closureEvidence.candidate.sourceTag
        controlPlaneImage = [string]$closureEvidence.candidate.controlPlaneImage
        edgeImage = [string]$closureEvidence.candidate.edgeImage
        policyVersion = [string]$closureEvidence.candidate.policyVersion
    }
    incident = [ordered]@{
        status = $CurrentIncidentStatus
        authoritativeExternalSystemRequired = $true
        performedByRepository = $false
    }
    assurance = [ordered]@{
        assessedAtUtc = $assessedAt.ToString('o')
        minimumWindowHours = $MinimumAssuranceWindowHours
        maxClosureEvidenceAgeHours = $MaxClosureEvidenceAgeHours
        maxAssessmentAgeMinutes = $MaxAssessmentAgeMinutes
        sustainedHealth = $SustainedHealthStatus
        errorBudget = $ErrorBudgetStatus
        securityReview = $SecurityReviewStatus
    }
    retrospective = [ordered]@{
        rootCauseAnalysis = $RootCauseAnalysisStatus
        correctiveActions = $CorrectiveActionsStatus
        status = $RetrospectiveStatus
        recorded = $retrospectiveRecorded
    }
    traffic = [ordered]@{
        expectedPercent = 100
        observedPercent = $ObservedTrafficPercent
        matchesClosure = $trafficMatchesClosure
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
        mutationPercentagePoints = 0
    }
    rollback = [ordered]@{
        targetPercent = [int]$closureEvidence.rollback.targetPercent
        emergencyTargetPercent = [int]$closureEvidence.rollback.emergencyTargetPercent
        authority = [string]$closureEvidence.rollback.authority
        procedureReference = [string]$closureEvidence.rollback.procedureReference
        retentionStatus = $RollbackRetentionStatus
    }
    audit = [ordered]@{
        status = $AuditEvidenceStatus
    }
    externalEvidence = [ordered]@{
        closureEvidenceGateReference = $ClosureEvidenceGateReference
        incidentRecordReference = $IncidentRecordReference
        assuranceWindowReference = $AssuranceWindowReference
        errorBudgetReference = $ErrorBudgetReference
        securityReviewReference = $SecurityReviewReference
        rootCauseAnalysisReference = $RootCauseAnalysisReference
        correctiveActionsReference = $CorrectiveActionsReference
        retrospectiveReference = $RetrospectiveReference
        trafficStateReference = $TrafficStateReference
        rollbackRetentionReference = $RollbackRetentionReference
        auditEvidenceReference = $AuditEvidenceReference
        collectedBy = $CollectedBy
    }
    decision = [ordered]@{
        retrospectiveRecorded = $retrospectiveRecorded
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'assurance-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Post-incident assurance evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Post-incident assurance and retrospective evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Retrospective recorded: $retrospectiveRecorded; next action: $nextAction"
Write-Host 'No cluster, traffic, incident, change-record, or retrospective-system changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Post-incident assurance is incomplete. Preserve rollback and collect or escalate authoritative evidence.'
}
