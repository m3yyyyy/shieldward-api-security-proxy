[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$PlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [switch]$CheckCluster
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

$resolvedEvidencePath = Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production incident containment evidence is missing: $resolvedEvidencePath"
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if (
    [int]$evidence.schemaVersion -ne 1 -or
    [string]$evidence.environment -ne 'production' -or
    [string]$evidence.evidenceType -ne 'incident-response-containment'
) {
    throw 'The supplied production incident containment evidence is unsupported.'
}
if ([string]$evidence.productionContext -ne $ExpectedProductionContext) {
    throw "The containment evidence targets '$($evidence.productionContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$evidence.namespace -ne 'shieldward') {
    throw "The containment evidence uses unsupported namespace '$($evidence.namespace)'."
}

$resolvedPlanPath = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    Resolve-LocalStatePath -Path ([string]$evidence.responsePlan.relativePath) -Description 'Recorded response plan path'
}
else {
    Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Recorded production incident response plan is missing: $resolvedPlanPath"
}
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $resolvedPlanPath `
    -ExpectedProductionContext $ExpectedProductionContext `
    -RequiredState Approved `
    -CheckCluster:$CheckCluster 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
    $planRelativePath -ne [string]$evidence.responsePlan.relativePath -or
    $planHash -ne [string]$evidence.responsePlan.sha256 -or
    [string]$plan.integrityDigest -ne [string]$evidence.responsePlan.integrityDigest -or
    [string]$plan.approval.approvalDigest -ne [string]$evidence.responsePlan.approvalDigest -or
    [string]$evidence.responsePlan.state -ne 'approved'
) {
    throw 'The approved incident response plan no longer matches containment evidence.'
}
if (
    [string]$evidence.incidentId -ne [string]$plan.incidentId -or
    [string]$evidence.changeId -ne [string]$plan.changeId -or
    [string]$evidence.response.action -ne [string]$plan.response.action -or
    [string]$evidence.response.authority -ne [string]$plan.response.authority -or
    [string]$evidence.response.procedureReference -ne [string]$plan.response.procedureReference
) {
    throw 'The containment evidence incident or response identity does not match the approved plan.'
}
if (
    [string]$evidence.candidate.version -ne [string]$plan.candidate.version -or
    [string]$evidence.candidate.sourceTag -ne [string]$plan.candidate.sourceTag -or
    [string]$evidence.candidate.controlPlaneImage -ne [string]$plan.candidate.controlPlaneImage -or
    [string]$evidence.candidate.edgeImage -ne [string]$plan.candidate.edgeImage -or
    [string]$evidence.candidate.policyVersion -ne [string]$plan.candidate.policyVersion
) {
    throw 'The containment evidence candidate does not match the approved response plan.'
}

if (
    [string]$evidence.traffic.enforcementStatus -notin @('confirmed', 'failed', 'unknown') -or
    [string]$evidence.verification.workloads -notin @('confirmed', 'failed', 'unknown') -or
    [string]$evidence.response.executionStatus -notin @('completed', 'failed', 'unknown') -or
    [string]$evidence.verification.incidentRecord -notin @('updated', 'missing', 'unknown')
) {
    throw 'The containment evidence contains an unsupported verification status.'
}
foreach ($reference in @(
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.trafficStateReference; Description = 'Traffic state reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.workloadEvidenceReference; Description = 'Workload evidence reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.responseExecutionReference; Description = 'Response execution reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.incidentRecordReference; Description = 'Incident record reference' }
    [pscustomobject]@{ Value = [string]$evidence.externalEvidence.collectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$expectedTrafficPercent = [int]$plan.traffic.targetPercent
$trafficMatchesPlan = [int]$evidence.traffic.observedPercent -eq $expectedTrafficPercent
$externallyEnforced = [string]$evidence.traffic.enforcementStatus -eq 'confirmed'
if (
    [string]$evidence.traffic.controller -ne [string]$plan.traffic.controller -or
    [int]$evidence.traffic.expectedPercent -ne $expectedTrafficPercent -or
    [bool]$evidence.traffic.matchesPlan -ne $trafficMatchesPlan -or
    [bool]$evidence.traffic.externallyEnforced -ne $externallyEnforced
) {
    throw 'The containment evidence traffic boundary is inconsistent with the approved response plan.'
}
if (
    ([string]$plan.response.action -eq 'disable-and-investigate' -and $expectedTrafficPercent -ne 0) -or
    ([string]$plan.response.action -eq 'rollback-to-75-and-investigate' -and $expectedTrafficPercent -ne 75) -or
    ([string]$plan.response.action -notin @('disable-and-investigate', 'rollback-to-75-and-investigate') -and $expectedTrafficPercent -ne 100)
) {
    throw 'The approved response action does not map to an exact 0, 75, or 100 percent traffic boundary.'
}

$approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
$executedAt = [DateTimeOffset]$evidence.response.executedAtUtc
$deadlineAt = [DateTimeOffset]$plan.response.deadlineAtUtc
$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$executionAgeAtCollection = $collectedAt.ToUniversalTime() - $executedAt.ToUniversalTime()
$deadlineMet = $executedAt.ToUniversalTime() -le $deadlineAt.ToUniversalTime()
if (
    $executedAt.ToUniversalTime() -lt $approvedAt.ToUniversalTime() -or
    $executionAgeAtCollection.TotalMinutes -lt -5 -or
    [int]$evidence.maxExecutionAgeMinutes -lt 5 -or
    [int]$evidence.maxExecutionAgeMinutes -gt 1440 -or
    $executionAgeAtCollection.TotalMinutes -gt [int]$evidence.maxExecutionAgeMinutes -or
    [DateTimeOffset]::UtcNow -lt $collectedAt.ToUniversalTime().AddMinutes(-5)
) {
    throw 'The containment evidence execution or collection timestamp is invalid.'
}
if (
    ([DateTimeOffset]$evidence.response.deadlineAtUtc).ToUniversalTime() -ne $deadlineAt.ToUniversalTime() -or
    [bool]$evidence.response.deadlineMet -ne $deadlineMet
) {
    throw 'The containment evidence response deadline calculation is invalid.'
}

$hasFailure = (
    [string]$evidence.traffic.enforcementStatus -eq 'failed' -or
    [string]$evidence.verification.workloads -eq 'failed' -or
    [string]$evidence.response.executionStatus -eq 'failed' -or
    [string]$evidence.verification.incidentRecord -eq 'missing' -or
    -not $trafficMatchesPlan -or
    -not $deadlineMet
)
$hasUnknown = @(
    [string]$evidence.traffic.enforcementStatus,
    [string]$evidence.verification.workloads,
    [string]$evidence.response.executionStatus,
    [string]$evidence.verification.incidentRecord
) -contains 'unknown'
$expectedOutcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$expectedNextAction = if ($expectedOutcome -ne 'passed') {
    'escalate-and-verify-containment'
}
else {
    switch ([string]$plan.response.action) {
        'reaccept-before-continuing' { 'perform-reacceptance-before-restoration' }
        'disable-and-investigate' { 'remediate-before-restoration' }
        'rotate-certificates-and-refresh-evidence' { 'collect-fresh-assurance' }
        'rollback-to-75-and-investigate' { 'remediate-and-prepare-recovery' }
        'investigate-and-refresh-evidence' { 'collect-fresh-assurance' }
        default { throw "Unsupported response action '$($plan.response.action)'." }
    }
}
if (
    [string]$evidence.outcome -ne $expectedOutcome -or
    [string]$evidence.decision.nextAction -ne $expectedNextAction -or
    [bool]$evidence.decision.reacceptanceRequired -ne [bool]$plan.decision.reacceptanceRequired
) {
    throw 'The containment outcome or next action is inconsistent with recorded verification states.'
}

$integrity = [ordered]@{
    responsePlanSha256 = $planHash
    responsePlanIntegrityDigest = [string]$plan.integrityDigest
    responsePlanApprovalDigest = [string]$plan.approval.approvalDigest
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    changeId = [string]$plan.changeId
    releaseVersion = [string]$plan.candidate.version
    responseAction = [string]$plan.response.action
    responseAuthority = [string]$plan.response.authority
    executedAtUtc = $executedAt.ToUniversalTime().ToString('o')
    deadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
    deadlineMet = $deadlineMet
    maxExecutionAgeMinutes = [int]$evidence.maxExecutionAgeMinutes
    trafficController = [string]$plan.traffic.controller
    expectedTrafficPercent = $expectedTrafficPercent
    observedTrafficPercent = [int]$evidence.traffic.observedPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = [string]$evidence.traffic.enforcementStatus
    workloadVerificationStatus = [string]$evidence.verification.workloads
    responseExecutionStatus = [string]$evidence.response.executionStatus
    incidentRecordStatus = [string]$evidence.verification.incidentRecord
    trafficStateReference = [string]$evidence.externalEvidence.trafficStateReference
    workloadEvidenceReference = [string]$evidence.externalEvidence.workloadEvidenceReference
    responseExecutionReference = [string]$evidence.externalEvidence.responseExecutionReference
    incidentRecordReference = [string]$evidence.externalEvidence.incidentRecordReference
    collectedBy = [string]$evidence.externalEvidence.collectedBy
    reacceptanceRequired = [bool]$plan.decision.reacceptanceRequired
    nextAction = $expectedNextAction
    outcome = $expectedOutcome
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
}
$expectedIntegrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)
if ($expectedIntegrityDigest -ne [string]$evidence.integrityDigest) {
    throw 'The production incident containment evidence integrity digest is invalid.'
}

Write-Host "Production incident containment evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Verified response boundary: $($evidence.traffic.observedPercent)%; next action: $expectedNextAction"
Write-Host 'This validator is read-only and does not enforce or change production traffic.'
