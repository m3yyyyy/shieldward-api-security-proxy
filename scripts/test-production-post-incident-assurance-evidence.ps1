[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$ClosureEvidencePath = '',
    [string]$ClosurePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [switch]$CheckCluster,
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

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Post-incident assurance evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'post-incident-assurance-and-retrospective'
) {
    throw 'The supplied post-incident assurance evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The post-incident evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The post-incident evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedClosureEvidencePath = if ([string]::IsNullOrWhiteSpace($ClosureEvidencePath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.closureEvidence.relativePath) -Description 'Recorded closure evidence path'
}
else {
    Resolve-LocalStatePath -Path $ClosureEvidencePath -Description 'ClosureEvidencePath'
}
if (-not (Test-Path -LiteralPath $resolvedClosureEvidencePath -PathType Leaf)) {
    throw "Recorded production incident recovery closure evidence is missing: $resolvedClosureEvidencePath"
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
$closureRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedClosureEvidencePath).Replace('\', '/')
$closureHash = (Get-FileHash -LiteralPath $resolvedClosureEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $closureRelativePath -ne [string]$evidence.closureEvidence.relativePath -or
    $closureHash -ne [string]$evidence.closureEvidence.sha256 -or
    [string]$closureEvidence.integrityDigest -ne [string]$evidence.closureEvidence.integrityDigest -or
    ([DateTimeOffset]$closureEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.closureEvidence.collectedAtUtc).ToUniversalTime().ToString('o') -or
    ([DateTimeOffset]$closureEvidence.execution.closedAtUtc).ToUniversalTime().ToString('o') -ne
        ([DateTimeOffset]$evidence.closureEvidence.closedAtUtc).ToUniversalTime().ToString('o') -or
    [bool]$evidence.closureEvidence.closureRecorded -ne $true
) {
    throw 'The approved production recovery closure evidence no longer matches post-incident assurance evidence.'
}
if (
    [string]$closureEvidence.outcome -ne 'passed' -or
    [bool]$closureEvidence.closure.recorded -ne $true -or
    [string]$closureEvidence.closure.incidentStatus -ne 'closed' -or
    [string]$closureEvidence.closure.changeRecordStatus -ne 'completed' -or
    [string]$closureEvidence.decision.nextAction -ne 'begin-post-incident-assurance-and-retrospective'
) {
    throw 'Post-incident assurance evidence requires passed authoritative closure evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$closureEvidence.incidentId -or
    [string]$evidence.closureChangeId -ne [string]$closureEvidence.closureChangeId
) {
    throw 'The post-incident assurance identity does not match closure evidence.'
}
if (
    [string]$evidence.candidate.version -ne [string]$closureEvidence.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$closureEvidence.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$closureEvidence.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$closureEvidence.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$closureEvidence.candidate.policyVersion
) {
    throw 'The post-incident assurance candidate does not match closure evidence.'
}

$statusContracts = @(
    [pscustomobject]@{ Name = 'current incident'; Actual = [string]$evidence.incident.status; Allowed = @('closed', 'reopened', 'unknown') }
    [pscustomobject]@{ Name = 'traffic enforcement'; Actual = [string]$evidence.traffic.enforcementStatus; Allowed = @('confirmed', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'sustained health'; Actual = [string]$evidence.assurance.sustainedHealth; Allowed = @('healthy', 'degraded', 'unknown') }
    [pscustomobject]@{ Name = 'error budget'; Actual = [string]$evidence.assurance.errorBudget; Allowed = @('within-budget', 'breached', 'unknown') }
    [pscustomobject]@{ Name = 'security review'; Actual = [string]$evidence.assurance.securityReview; Allowed = @('complete', 'failed', 'unknown') }
    [pscustomobject]@{ Name = 'root-cause analysis'; Actual = [string]$evidence.retrospective.rootCauseAnalysis; Allowed = @('complete', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'corrective actions'; Actual = [string]$evidence.retrospective.correctiveActions; Allowed = @('tracked', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'retrospective'; Actual = [string]$evidence.retrospective.status; Allowed = @('completed', 'incomplete', 'unknown') }
    [pscustomobject]@{ Name = 'rollback retention'; Actual = [string]$evidence.rollback.retentionStatus; Allowed = @('retained', 'missing', 'unknown') }
    [pscustomobject]@{ Name = 'audit evidence'; Actual = [string]$evidence.audit.status; Allowed = @('complete', 'incomplete', 'unknown') }
)
foreach ($status in $statusContracts) {
    if ($status.Allowed -notcontains $status.Actual) {
        throw "The post-incident assurance evidence contains unsupported $($status.Name) status '$($status.Actual)'."
    }
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.closureEvidenceGateReference; Description = 'Closure evidence gate reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.incidentRecordReference; Description = 'Incident record reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.assuranceWindowReference; Description = 'Assurance window reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.errorBudgetReference; Description = 'Error budget reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.securityReviewReference; Description = 'Security review reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rootCauseAnalysisReference; Description = 'Root-cause analysis reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.correctiveActionsReference; Description = 'Corrective-actions reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.retrospectiveReference; Description = 'Retrospective reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic-state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.rollbackRetentionReference; Description = 'Rollback-retention reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.auditEvidenceReference; Description = 'Audit-evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.collectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

if (
    [bool]$evidence.incident.authoritativeExternalSystemRequired -ne $true -or
    [bool]$evidence.incident.performedByRepository -ne $false
) {
    throw 'Post-incident assurance must preserve external records and repository read-only separation.'
}

$trafficMatchesClosure = [int]$evidence.traffic.observedPercent -eq [int]$closureEvidence.traffic.observedPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [int]$closureEvidence.traffic.observedPercent -ne 100 -or
    [int]$evidence.traffic.expectedPercent -ne 100 -or
    [bool]$evidence.traffic.matchesClosure -ne $trafficMatchesClosure -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced -or
    [int]$evidence.traffic.mutationPercentagePoints -ne 0
) {
    throw 'The post-incident traffic evidence is inconsistent with the closed 100-percent no-mutation boundary.'
}
if (
    [int]$evidence.rollback.targetPercent -ne [int]$closureEvidence.rollback.targetPercent -or
    [int]$evidence.rollback.emergencyTargetPercent -ne [int]$closureEvidence.rollback.emergencyTargetPercent -or
    [string]$evidence.rollback.authority -ne [string]$closureEvidence.rollback.authority -or
    [string]$evidence.rollback.procedureReference -ne [string]$closureEvidence.rollback.procedureReference
) {
    throw 'The post-incident rollback evidence is inconsistent with closure evidence.'
}

$closedAt = ([DateTimeOffset]$closureEvidence.execution.closedAtUtc).ToUniversalTime()
$closureCollectedAt = ([DateTimeOffset]$closureEvidence.collectedAtUtc).ToUniversalTime()
$assessedAt = ([DateTimeOffset]$evidence.assurance.assessedAtUtc).ToUniversalTime()
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$assuranceWindow = $assessedAt - $closedAt
$closureEvidenceAgeAtCollection = $collectedAt - $closureCollectedAt
$assessmentAgeAtCollection = $collectedAt - $assessedAt
if (
    [int]$evidence.assurance.minimumWindowHours -lt 1 -or
    [int]$evidence.assurance.minimumWindowHours -gt 720 -or
    $assuranceWindow.TotalHours -lt [int]$evidence.assurance.minimumWindowHours -or
    [int]$evidence.assurance.maxClosureEvidenceAgeHours -lt 1 -or
    [int]$evidence.assurance.maxClosureEvidenceAgeHours -gt 2160 -or
    $closureEvidenceAgeAtCollection.TotalHours -lt -1 -or
    $closureEvidenceAgeAtCollection.TotalHours -gt [int]$evidence.assurance.maxClosureEvidenceAgeHours -or
    [int]$evidence.assurance.maxAssessmentAgeMinutes -lt 5 -or
    [int]$evidence.assurance.maxAssessmentAgeMinutes -gt 1440 -or
    $assessmentAgeAtCollection.TotalMinutes -lt -5 -or
    $assessmentAgeAtCollection.TotalMinutes -gt [int]$evidence.assurance.maxAssessmentAgeMinutes -or
    $referenceNow -lt $collectedAt.AddMinutes(-5)
) {
    throw 'The post-incident assurance window, assessment, or collection timestamp is invalid.'
}

$hasFailure = (
    [string]$evidence.traffic.enforcementStatus -eq 'failed' -or
    [string]$evidence.incident.status -eq 'reopened' -or
    [string]$evidence.assurance.sustainedHealth -eq 'degraded' -or
    [string]$evidence.assurance.errorBudget -eq 'breached' -or
    [string]$evidence.assurance.securityReview -eq 'failed' -or
    [string]$evidence.retrospective.rootCauseAnalysis -eq 'incomplete' -or
    [string]$evidence.retrospective.correctiveActions -eq 'incomplete' -or
    [string]$evidence.retrospective.status -eq 'incomplete' -or
    [string]$evidence.rollback.retentionStatus -eq 'missing' -or
    [string]$evidence.audit.status -eq 'incomplete' -or
    -not $trafficMatchesClosure
)
$hasUnknown = @(
    [string]$evidence.traffic.enforcementStatus,
    [string]$evidence.incident.status,
    [string]$evidence.assurance.sustainedHealth,
    [string]$evidence.assurance.errorBudget,
    [string]$evidence.assurance.securityReview,
    [string]$evidence.retrospective.rootCauseAnalysis,
    [string]$evidence.retrospective.correctiveActions,
    [string]$evidence.retrospective.status,
    [string]$evidence.rollback.retentionStatus,
    [string]$evidence.audit.status
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedRetrospectiveRecorded = (
    [string]$evidence.retrospective.rootCauseAnalysis -eq 'complete' -and
    [string]$evidence.retrospective.correctiveActions -eq 'tracked' -and
    [string]$evidence.retrospective.status -eq 'completed'
)
$expectedNextAction = switch ($expectedOutcome) {
    'passed' { 'resume-continuous-production-assurance' }
    'failed' { 'reopen-or-escalate-incident-and-preserve-rollback' }
    default { 'treat-assurance-as-incomplete-and-collect-evidence' }
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [bool]$evidence.retrospective.recorded -ne $expectedRetrospectiveRecorded -or
    [bool]$evidence.decision.retrospectiveRecorded -ne $expectedRetrospectiveRecorded -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction
) {
    throw 'The post-incident assurance outcome is inconsistent with recorded evidence.'
}

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
    minimumAssuranceWindowHours = [int]$evidence.assurance.minimumWindowHours
    maxClosureEvidenceAgeHours = [int]$evidence.assurance.maxClosureEvidenceAgeHours
    maxAssessmentAgeMinutes = [int]$evidence.assurance.maxAssessmentAgeMinutes
    currentIncidentStatus = [string]$evidence.incident.status
    expectedTrafficPercent = 100
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesClosure = $trafficMatchesClosure
    trafficEnforcementStatus = [string]$evidence.traffic.enforcementStatus
    sustainedHealthStatus = [string]$evidence.assurance.sustainedHealth
    errorBudgetStatus = [string]$evidence.assurance.errorBudget
    securityReviewStatus = [string]$evidence.assurance.securityReview
    rootCauseAnalysisStatus = [string]$evidence.retrospective.rootCauseAnalysis
    correctiveActionsStatus = [string]$evidence.retrospective.correctiveActions
    retrospectiveStatus = [string]$evidence.retrospective.status
    rollbackRetentionStatus = [string]$evidence.rollback.retentionStatus
    auditEvidenceStatus = [string]$evidence.audit.status
    rollbackTargetPercent = [int]$closureEvidence.rollback.targetPercent
    rollbackEmergencyTargetPercent = [int]$closureEvidence.rollback.emergencyTargetPercent
    closureEvidenceGateReference = [string]$evidence.externalEvidence.closureEvidenceGateReference
    incidentRecordReference = [string]$evidence.externalEvidence.incidentRecordReference
    assuranceWindowReference = [string]$evidence.externalEvidence.assuranceWindowReference
    errorBudgetReference = [string]$evidence.externalEvidence.errorBudgetReference
    securityReviewReference = [string]$evidence.externalEvidence.securityReviewReference
    rootCauseAnalysisReference = [string]$evidence.externalEvidence.rootCauseAnalysisReference
    correctiveActionsReference = [string]$evidence.externalEvidence.correctiveActionsReference
    retrospectiveReference = [string]$evidence.externalEvidence.retrospectiveReference
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    rollbackRetentionReference = [string]$evidence.externalEvidence.rollbackRetentionReference
    auditEvidenceReference = [string]$evidence.externalEvidence.auditEvidenceReference
    collectedBy = [string]$evidence.externalEvidence.collectedBy
    retrospectiveRecorded = $expectedRetrospectiveRecorded
    outcome = $expectedOutcome
    nextAction = $expectedNextAction
    collectedAtUtc = $collectedAt.ToString('o')
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$evidence.integrityDigest) {
    throw 'The post-incident assurance evidence integrity digest is invalid.'
}

Write-Host "Post-incident assurance and retrospective evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Retrospective recorded: $expectedRetrospectiveRecorded; next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not change traffic, incidents, external records, or rollback state.'
