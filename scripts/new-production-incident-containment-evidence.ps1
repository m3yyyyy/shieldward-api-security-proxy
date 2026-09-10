[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-response/response.json',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [DateTimeOffset]$ExecutedAtUtc,

    [Parameter(Mandatory)]
    [ValidateRange(0, 100)]
    [int]$ObservedTrafficPercent,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$TrafficEnforcementStatus,

    [Parameter(Mandatory)]
    [ValidateSet('confirmed', 'failed', 'unknown')]
    [string]$WorkloadVerificationStatus,

    [Parameter(Mandatory)]
    [ValidateSet('completed', 'failed', 'unknown')]
    [string]$ResponseExecutionStatus,

    [Parameter(Mandatory)]
    [ValidateSet('updated', 'missing', 'unknown')]
    [string]$IncidentRecordStatus,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficStateReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResponseExecutionReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IncidentRecordReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectedBy,

    [ValidateRange(5, 1440)]
    [int]$MaxExecutionAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-containment',
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

foreach ($reference in @(
    [pscustomobject]@{ Value = $TrafficStateReference; Description = 'TrafficStateReference' }
    [pscustomobject]@{ Value = $WorkloadEvidenceReference; Description = 'WorkloadEvidenceReference' }
    [pscustomobject]@{ Value = $ResponseExecutionReference; Description = 'ResponseExecutionReference' }
    [pscustomobject]@{ Value = $IncidentRecordReference; Description = 'IncidentRecordReference' }
    [pscustomobject]@{ Value = $CollectedBy; Description = 'CollectedBy' }
)) {
    Assert-EvidenceReference -Value $reference.Value -Description $reference.Description
}

$resolvedPlanPath = Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident response plan is missing: $resolvedPlanPath"
}
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $resolvedPlanPath `
    -ExpectedProductionContext $ExpectedProductionContext `
    -RequiredState Approved `
    -CheckCluster:$CheckCluster 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$approvedAt = [DateTimeOffset]$plan.approval.approvedAtUtc
$deadlineAt = [DateTimeOffset]$plan.response.deadlineAtUtc
$executedAt = $ExecutedAtUtc.ToUniversalTime()
$now = [DateTimeOffset]::UtcNow
$executionAge = $now - $executedAt
if (
    $executedAt -lt $approvedAt.ToUniversalTime() -or
    $executionAge.TotalMinutes -lt -5 -or
    $executionAge.TotalMinutes -gt $MaxExecutionAgeMinutes
) {
    throw "ExecutedAtUtc must follow approval and be within $MaxExecutionAgeMinutes minutes of current UTC time."
}

$deadlineMet = $executedAt -le $deadlineAt.ToUniversalTime()
$expectedTrafficPercent = [int]$plan.traffic.targetPercent
$trafficMatchesPlan = $ObservedTrafficPercent -eq $expectedTrafficPercent
$hasFailure = (
    $TrafficEnforcementStatus -eq 'failed' -or
    $WorkloadVerificationStatus -eq 'failed' -or
    $ResponseExecutionStatus -eq 'failed' -or
    $IncidentRecordStatus -eq 'missing' -or
    -not $trafficMatchesPlan -or
    -not $deadlineMet
)
$hasUnknown = @(
    $TrafficEnforcementStatus,
    $WorkloadVerificationStatus,
    $ResponseExecutionStatus,
    $IncidentRecordStatus
) -contains 'unknown'
$outcome = if ($hasFailure) { 'failed' } elseif ($hasUnknown) { 'unknown' } else { 'passed' }
$nextAction = if ($outcome -ne 'passed') {
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

$collectedAt = [DateTimeOffset]::UtcNow
$planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedPlanPath).Replace('\', '/')
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
    executedAtUtc = $executedAt.ToString('o')
    deadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
    deadlineMet = $deadlineMet
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    trafficController = [string]$plan.traffic.controller
    expectedTrafficPercent = $expectedTrafficPercent
    observedTrafficPercent = $ObservedTrafficPercent
    trafficMatchesPlan = $trafficMatchesPlan
    trafficEnforcementStatus = $TrafficEnforcementStatus
    workloadVerificationStatus = $WorkloadVerificationStatus
    responseExecutionStatus = $ResponseExecutionStatus
    incidentRecordStatus = $IncidentRecordStatus
    trafficStateReference = $TrafficStateReference
    workloadEvidenceReference = $WorkloadEvidenceReference
    responseExecutionReference = $ResponseExecutionReference
    incidentRecordReference = $IncidentRecordReference
    collectedBy = $CollectedBy
    reacceptanceRequired = [bool]$plan.decision.reacceptanceRequired
    nextAction = $nextAction
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'incident-response-containment'
    outcome = $outcome
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = [string]$plan.incidentId
    changeId = [string]$plan.changeId
    maxExecutionAgeMinutes = $MaxExecutionAgeMinutes
    responsePlan = [ordered]@{
        relativePath = $planRelativePath
        sha256 = $planHash
        integrityDigest = [string]$plan.integrityDigest
        approvalDigest = [string]$plan.approval.approvalDigest
        approvedAtUtc = $approvedAt.ToUniversalTime().ToString('o')
        state = [string]$plan.state
    }
    candidate = [ordered]@{
        version = [string]$plan.candidate.version
        sourceTag = [string]$plan.candidate.sourceTag
        controlPlaneImage = [string]$plan.candidate.controlPlaneImage
        edgeImage = [string]$plan.candidate.edgeImage
        policyVersion = [string]$plan.candidate.policyVersion
    }
    response = [ordered]@{
        action = [string]$plan.response.action
        authority = [string]$plan.response.authority
        procedureReference = [string]$plan.response.procedureReference
        executedAtUtc = $executedAt.ToString('o')
        deadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
        deadlineMet = $deadlineMet
        executionStatus = $ResponseExecutionStatus
    }
    traffic = [ordered]@{
        controller = [string]$plan.traffic.controller
        expectedPercent = $expectedTrafficPercent
        observedPercent = $ObservedTrafficPercent
        matchesPlan = $trafficMatchesPlan
        enforcementStatus = $TrafficEnforcementStatus
        externallyEnforced = $TrafficEnforcementStatus -eq 'confirmed'
    }
    verification = [ordered]@{
        workloads = $WorkloadVerificationStatus
        incidentRecord = $IncidentRecordStatus
    }
    externalEvidence = [ordered]@{
        trafficStateReference = $TrafficStateReference
        workloadEvidenceReference = $WorkloadEvidenceReference
        responseExecutionReference = $ResponseExecutionReference
        incidentRecordReference = $IncidentRecordReference
        collectedBy = $CollectedBy
    }
    decision = [ordered]@{
        reacceptanceRequired = [bool]$plan.decision.reacceptanceRequired
        nextAction = $nextAction
    }
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$fileName = 'containment-{0}.json' -f $collectedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory $fileName
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production incident containment evidence already exists: $evidencePath. Use -Force only to replace this generated record."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Production incident containment evidence recorded at $evidencePath with outcome '$outcome'."
Write-Host "Observed response boundary: $ObservedTrafficPercent%; required next action: $nextAction"
Write-Host 'No cluster or traffic changes were made.'
if ($outcome -ne 'passed') {
    Write-Warning 'Containment is not proven. Escalate through the authoritative incident system.'
}
