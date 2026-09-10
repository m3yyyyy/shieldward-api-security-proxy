[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AssuranceEvidencePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$IncidentId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{2,127}$')]
    [string]$ChangeId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResponseOwner,

    [Parameter(Mandatory)]
    [ValidateSet(
        'reaccept-before-continuing',
        'disable-and-investigate',
        'rotate-certificates-and-refresh-evidence',
        'rollback-to-75-and-investigate',
        'investigate-and-refresh-evidence'
    )]
    [string]$ResponseAction,

    [ValidateRange(5, 1440)]
    [int]$ResponseDeadlineMinutes = 15,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

    [string]$OutputDirectory = '.shieldward/production-incident-response',
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

Assert-OperatorValue -Value $ResponseOwner -Description 'ResponseOwner'
Assert-OperatorValue -Value $IncidentId -Description 'IncidentId'
Assert-OperatorValue -Value $ChangeId -Description 'ChangeId'
$resolvedEvidencePath = Resolve-LocalStatePath -Path $AssuranceEvidencePath -Description 'AssuranceEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
    throw "Production assurance evidence is missing: $resolvedEvidencePath"
}

& (Join-Path $PSScriptRoot 'test-production-assurance-evidence.ps1') `
    -EvidencePath $resolvedEvidencePath `
    -ExpectedProductionContext $ExpectedProductionContext `
    -CheckCluster:$CheckCluster 6>$null

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
if ([string]$evidence.outcome -notin @('failed', 'unknown')) {
    throw "Incident response planning requires failed or unknown assurance evidence; outcome is '$($evidence.outcome)'."
}

$allowedResponseActions = switch ([string]$evidence.decision.requiredAction) {
    'reaccept-before-continuing' { @('reaccept-before-continuing') }
    'disable-and-investigate' { @('disable-and-investigate') }
    'rotate-certificates-and-refresh-evidence' { @('rotate-certificates-and-refresh-evidence') }
    'rollback-or-disable-and-investigate' { @('rollback-to-75-and-investigate', 'disable-and-investigate') }
    'investigate-and-refresh-evidence' { @('investigate-and-refresh-evidence', 'disable-and-investigate') }
    default { throw "Unsupported assurance action '$($evidence.decision.requiredAction)'." }
}
if ($ResponseAction -notin $allowedResponseActions) {
    throw "ResponseAction '$ResponseAction' is not allowed for assurance action '$($evidence.decision.requiredAction)'."
}
if (-not [string]::Equals($ResponseOwner, [string]$evidence.rollback.authority, [StringComparison]::Ordinal)) {
    throw "ResponseOwner must exactly match the recorded response authority '$($evidence.rollback.authority)'."
}

$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$now = [DateTimeOffset]::UtcNow
$evidenceAge = $now - $collectedAt.ToUniversalTime()
if ($evidenceAge.TotalMinutes -lt -5 -or $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes) {
    throw "Production assurance evidence is outside the response age of $MaxEvidenceAgeMinutes minutes. Collect a current fail-closed snapshot."
}

$targetTrafficPercent = switch ($ResponseAction) {
    'disable-and-investigate' { 0 }
    'rollback-to-75-and-investigate' { [int]$evidence.rollback.targetPercent }
    default { [int]$evidence.traffic.observedTrafficPercent }
}
if ($ResponseAction -eq 'rollback-to-75-and-investigate' -and $targetTrafficPercent -ne 75) {
    throw 'The recorded rollback cohort is not exactly 75 percent.'
}

$generatedAt = [DateTimeOffset]::UtcNow
$deadlineAt = $generatedAt.AddMinutes($ResponseDeadlineMinutes)
$evidenceHash = (Get-FileHash -LiteralPath $resolvedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$evidenceRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedEvidencePath).Replace('\', '/')
$requiredApprovalStatement = "APPROVE PRODUCTION INCIDENT RESPONSE $IncidentId $ChangeId FOR $ExpectedProductionContext ACTION $ResponseAction"

$integrity = [ordered]@{
    assuranceEvidenceSha256 = $evidenceHash
    assuranceEvidenceIntegrityDigest = [string]$evidence.integrityDigest
    assuranceOutcome = [string]$evidence.outcome
    assuranceRequiredAction = [string]$evidence.decision.requiredAction
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = $IncidentId
    changeId = $ChangeId
    generatedAtUtc = $generatedAt.ToUniversalTime().ToString('o')
    responseDeadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
    responseDeadlineMinutes = $ResponseDeadlineMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    releaseVersion = [string]$evidence.candidate.version
    controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
    edgeImage = [string]$evidence.candidate.edgeImage
    policyVersion = [string]$evidence.candidate.policyVersion
    currentTrafficPercent = [int]$evidence.traffic.observedTrafficPercent
    targetTrafficPercent = $targetTrafficPercent
    trafficController = [string]$evidence.traffic.controller
    responseAction = $ResponseAction
    responseOwner = $ResponseOwner
    rollbackAuthority = [string]$evidence.rollback.authority
    rollbackProcedureReference = [string]$evidence.rollback.procedureReference
    reacceptanceRequired = [bool]$evidence.decision.reacceptanceRequired
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$plan = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    operation = 'production-incident-response'
    state = 'pending'
    generatedAtUtc = $generatedAt.ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    incidentId = $IncidentId
    changeId = $ChangeId
    responseDeadlineMinutes = $ResponseDeadlineMinutes
    maxEvidenceAgeMinutes = $MaxEvidenceAgeMinutes
    assuranceEvidence = [ordered]@{
        relativePath = $evidenceRelativePath
        sha256 = $evidenceHash
        integrityDigest = [string]$evidence.integrityDigest
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        nextReviewDueAtUtc = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime().ToString('o')
        outcome = [string]$evidence.outcome
        requiredAction = [string]$evidence.decision.requiredAction
    }
    candidate = [ordered]@{
        version = [string]$evidence.candidate.version
        sourceTag = [string]$evidence.candidate.sourceTag
        controlPlaneImage = [string]$evidence.candidate.controlPlaneImage
        edgeImage = [string]$evidence.candidate.edgeImage
        policyVersion = [string]$evidence.candidate.policyVersion
    }
    traffic = [ordered]@{
        currentPercent = [int]$evidence.traffic.observedTrafficPercent
        targetPercent = $targetTrafficPercent
        controller = [string]$evidence.traffic.controller
        externalEnforcementRequired = $true
    }
    response = [ordered]@{
        action = $ResponseAction
        authority = $ResponseOwner
        deadlineAtUtc = $deadlineAt.ToUniversalTime().ToString('o')
        procedureReference = [string]$evidence.rollback.procedureReference
        externalIncidentSystemRequired = $true
        externalTrafficControllerRequired = $true
        executionState = 'not-started'
    }
    decision = [ordered]@{
        sourceAction = [string]$evidence.decision.requiredAction
        reacceptanceRequired = [bool]$evidence.decision.reacceptanceRequired
    }
    rollback = [ordered]@{
        mode = [string]$evidence.rollback.mode
        targetPercent = [int]$evidence.rollback.targetPercent
        emergencyTargetPercent = [int]$evidence.rollback.emergencyTargetPercent
        authority = [string]$evidence.rollback.authority
        procedureReference = [string]$evidence.rollback.procedureReference
    }
    approval = [ordered]@{
        status = 'pending'
        owner = $ResponseOwner
        requiredStatement = $requiredApprovalStatement
        approvedBy = $null
        approvedAtUtc = $null
        approvedAtUnixSeconds = $null
        approvalStatement = $null
        approvalDigest = $null
    }
    safeguards = @(
        'failed-or-unknown-assurance-evidence'
        'fresh-response-evidence'
        'immutable-assurance-evidence'
        'exact-production-context'
        'explicit-incident-and-change-records'
        'recorded-response-authority'
        'explicit-response-action'
        'bounded-response-deadline'
        'external-traffic-enforcement'
        'no-automatic-production-mutation'
        'preserve-audit-evidence'
    )
    integrityDigest = $integrityDigest
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$planPath = Join-Path $resolvedOutputDirectory 'response.json'
if ((Test-Path -LiteralPath $planPath) -and -not $Force) {
    throw "Production incident response plan already exists: $planPath. Use -Force only to replace this generated plan."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $planPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Pending production incident response plan created at $planPath"
Write-Host "Required approval statement: $requiredApprovalStatement"
Write-Host 'No cluster or traffic changes were made.'
