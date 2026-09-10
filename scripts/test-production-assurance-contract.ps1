[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Set-AssuranceEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $nextReviewDueAt = [DateTimeOffset]$Evidence['schedule']['nextReviewDueAtUtc']
    $integrity = [ordered]@{
        acceptedFullTrafficEvidenceSha256 = [string]$Evidence['acceptedFullTrafficEvidence']['sha256']
        acceptedFullTrafficEvidenceIntegrityDigest = [string]$Evidence['acceptedFullTrafficEvidence']['integrityDigest']
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        nextReviewDueAtUtc = $nextReviewDueAt.ToUniversalTime().ToString('o')
        reviewIntervalMinutes = [int]$Evidence['schedule']['reviewIntervalMinutes']
        productionContext = [string]$Evidence['productionContext']
        releaseVersion = [string]$Evidence['candidate']['version']
        sourceTag = [string]$Evidence['candidate']['sourceTag']
        controlPlaneImage = [string]$Evidence['candidate']['controlPlaneImage']
        edgeImage = [string]$Evidence['candidate']['edgeImage']
        policyVersion = [string]$Evidence['candidate']['policyVersion']
        trafficController = [string]$Evidence['traffic']['controller']
        observedTrafficPercent = [int]$Evidence['traffic']['observedTrafficPercent']
        errorBudgetStatus = [string]$Evidence['signals']['errorBudget']
        alertStatus = [string]$Evidence['signals']['alerts']
        functionalStatus = [string]$Evidence['signals']['functional']
        dependencyStatus = [string]$Evidence['signals']['dependencies']
        operationalStatus = [string]$Evidence['signals']['operations']
        capacityStatus = [string]$Evidence['signals']['capacity']
        securityStatus = [string]$Evidence['signals']['security']
        imageDriftStatus = [string]$Evidence['drift']['images']
        policyDriftStatus = [string]$Evidence['drift']['policy']
        configurationDriftStatus = [string]$Evidence['drift']['configuration']
        identityDriftStatus = [string]$Evidence['drift']['identity']
        certificateStatus = [string]$Evidence['drift']['certificates']
        routingDriftStatus = [string]$Evidence['drift']['routing']
        trafficStateReference = [string]$Evidence['externalEvidence']['trafficStateReference']
        monitoringEvidenceReference = [string]$Evidence['externalEvidence']['monitoringEvidenceReference']
        driftEvidenceReference = [string]$Evidence['externalEvidence']['driftEvidenceReference']
        reviewedBy = [string]$Evidence['externalEvidence']['reviewedBy']
        reacceptanceRequired = [bool]$Evidence['decision']['reacceptanceRequired']
        requiredAction = [string]$Evidence['decision']['requiredAction']
        outcome = [string]$Evidence['outcome']
    }
    $Evidence['integrityDigest'] = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$trafficContractRoot = Join-Path $repoRoot '.shieldward/production-traffic-contract'
$stagingEvidencePath = Join-Path $trafficContractRoot 'staging-evidence.json'
$initialPlanPath = Join-Path $trafficContractRoot 'initial-plan/installation.json'
$baselinePath = Join-Path $trafficContractRoot 'production-baseline.json'
$trafficPlanPath = Join-Path $trafficContractRoot 'traffic-plan/activation.json'
$expansionContractRoot = Join-Path $repoRoot '.shieldward/production-expansion-contract'
$canaryEvidencePath = Join-Path $expansionContractRoot 'canary-evidence.json'
$expansionPlanPath = Join-Path $expansionContractRoot 'expansion-plan/expansion.json'
$progressiveContractRoot = Join-Path $repoRoot '.shieldward/production-progressive-contract'
$expansionEvidencePath = Join-Path $progressiveContractRoot 'expansion-evidence.json'
$progressivePlanPath = Join-Path $progressiveContractRoot 'progressive-plan/expansion.json'
$secondContractRoot = Join-Path $repoRoot '.shieldward/production-second-expansion-contract'
$progressiveEvidencePath = Join-Path $secondContractRoot 'progressive-evidence.json'
$secondPlanPath = Join-Path $secondContractRoot 'second-plan/expansion.json'
$finalContractRoot = Join-Path $repoRoot '.shieldward/production-final-expansion-contract'
$secondEvidencePath = Join-Path $finalContractRoot 'second-expansion-evidence.json'
$finalPlanPath = Join-Path $finalContractRoot 'final-plan/expansion.json'
$steadyStateContractRoot = Join-Path $repoRoot '.shieldward/production-steady-state-contract'
$acceptedEvidencePath = Join-Path $steadyStateContractRoot 'full-traffic-evidence.json'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-contract'
$assuranceEvidencePath = Join-Path $testRoot 'assurance-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$driftEvidencePath = Join-Path $testRoot 'drift-evidence.json'
$failedEvidencePath = Join-Path $testRoot 'failed-evidence.json'
$certificateEvidencePath = Join-Path $testRoot 'certificate-evidence.json'
$incompleteEvidencePath = Join-Path $testRoot 'incomplete-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$nonFullEvidencePath = Join-Path $testRoot 'non-full-evidence.json'
$decisionEvidencePath = Join-Path $testRoot 'decision-evidence.json'

& (Join-Path $PSScriptRoot 'test-production-steady-state-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$chainArguments = @{
    AcceptedFullTrafficEvidencePath = $acceptedEvidencePath
    FinalExpansionPlanPath = $finalPlanPath
    SecondExpansionEvidencePath = $secondEvidencePath
    SecondExpansionPlanPath = $secondPlanPath
    ProgressiveEvidencePath = $progressiveEvidencePath
    ProgressivePlanPath = $progressivePlanPath
    ExpansionEvidencePath = $expansionEvidencePath
    ExpansionPlanPath = $expansionPlanPath
    CanaryEvidencePath = $canaryEvidencePath
    TrafficPlanPath = $trafficPlanPath
    BaselineEvidencePath = $baselinePath
    InitialPlanPath = $initialPlanPath
    StagingEvidencePath = $stagingEvidencePath
    ExpectedProductionContext = 'production-contract'
}

$acceptedEvidence = Get-Content -Raw -LiteralPath $acceptedEvidencePath | ConvertFrom-Json
$acceptedHash = (Get-FileHash -LiteralPath $acceptedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$collectedAt = [DateTimeOffset]::UtcNow
$reviewIntervalMinutes = 60
$assuranceEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'ongoing-production-assurance'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    acceptedFullTrafficEvidence = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $acceptedEvidencePath).Replace('\', '/')
        sha256 = $acceptedHash
        integrityDigest = [string]$acceptedEvidence.integrityDigest
        collectedAtUtc = ([DateTimeOffset]$acceptedEvidence.collectedAtUtc).ToUniversalTime().ToString('o')
        outcome = 'passed'
    }
    candidate = [ordered]@{
        version = [string]$acceptedEvidence.candidate.version
        sourceTag = [string]$acceptedEvidence.candidate.sourceTag
        controlPlaneImage = [string]$acceptedEvidence.candidate.controlPlaneImage
        edgeImage = [string]$acceptedEvidence.candidate.edgeImage
        policyVersion = [string]$acceptedEvidence.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$acceptedEvidence.traffic.controller
        observedTrafficPercent = 100
        externallyEnforced = $true
    }
    schedule = [ordered]@{
        reviewIntervalMinutes = $reviewIntervalMinutes
        nextReviewDueAtUtc = $collectedAt.AddMinutes($reviewIntervalMinutes).ToUniversalTime().ToString('o')
    }
    signals = [ordered]@{
        errorBudget = 'within-budget'
        alerts = 'clear'
        functional = 'passed'
        dependencies = 'healthy'
        operations = 'healthy'
        capacity = 'healthy'
        security = 'clear'
    }
    drift = [ordered]@{
        images = 'clear'
        policy = 'clear'
        configuration = 'clear'
        identity = 'clear'
        certificates = 'healthy'
        routing = 'clear'
    }
    externalEvidence = [ordered]@{
        trafficStateReference = 'TRAFFIC-STATE-006'
        monitoringEvidenceReference = 'MONITORING-006'
        driftEvidenceReference = 'DRIFT-SCAN-006'
        reviewedBy = 'Assurance Reviewer'
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    decision = [ordered]@{
        reacceptanceRequired = $false
        requiredAction = 'continue-monitoring'
    }
    rollback = [ordered]@{
        mode = [string]$acceptedEvidence.rollback.mode
        targetPercent = [int]$acceptedEvidence.rollback.targetPercent
        emergencyTargetPercent = [int]$acceptedEvidence.rollback.emergencyTargetPercent
        authority = [string]$acceptedEvidence.rollback.authority
        procedureReference = [string]$acceptedEvidence.rollback.procedureReference
    }
    integrityDigest = ''
}
$evidenceHashtable = $assuranceEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-AssuranceEvidenceIntegrity -Evidence $evidenceHashtable
Write-JsonFile -Path $assuranceEvidencePath -Value $evidenceHashtable

$gateArguments = $chainArguments.Clone()
$gateArguments.EvidencePath = $assuranceEvidencePath
$gateArguments.MaxEvidenceAgeMinutes = 60
$validationArguments = $chainArguments.Clone()
$validationArguments.EvidencePath = $assuranceEvidencePath
& (Join-Path $PSScriptRoot 'test-production-assurance-evidence.ps1') @validationArguments | Out-Null
& (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @gateArguments | Out-Null

$unknownEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['drift']['policy'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
$unknownEvidence['decision']['requiredAction'] = 'investigate-and-refresh-evidence'
Set-AssuranceEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownSignalRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $unknownEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $unknownSignalRejected = $true
}
if (-not $unknownSignalRejected) {
    throw 'The assurance gate allowed an unknown drift signal.'
}

$driftEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$driftEvidence['drift']['configuration'] = 'detected'
$driftEvidence['outcome'] = 'failed'
$driftEvidence['decision']['reacceptanceRequired'] = $true
$driftEvidence['decision']['requiredAction'] = 'reaccept-before-continuing'
Set-AssuranceEvidenceIntegrity -Evidence $driftEvidence
Write-JsonFile -Path $driftEvidencePath -Value $driftEvidence
$materialDriftRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $driftEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $materialDriftRejected = $true
}
if (-not $materialDriftRejected) {
    throw 'The assurance gate allowed material configuration drift without re-acceptance.'
}

$failedEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$failedEvidence['signals']['alerts'] = 'firing'
$failedEvidence['outcome'] = 'failed'
$failedEvidence['decision']['requiredAction'] = 'rollback-or-disable-and-investigate'
Set-AssuranceEvidenceIntegrity -Evidence $failedEvidence
Write-JsonFile -Path $failedEvidencePath -Value $failedEvidence
$failedHealthRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $failedEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $failedHealthRejected = $true
}
if (-not $failedHealthRejected) {
    throw 'The assurance gate allowed failed production health.'
}

$certificateEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$certificateEvidence['drift']['certificates'] = 'expiring'
$certificateEvidence['outcome'] = 'failed'
$certificateEvidence['decision']['requiredAction'] = 'rotate-certificates-and-refresh-evidence'
Set-AssuranceEvidenceIntegrity -Evidence $certificateEvidence
Write-JsonFile -Path $certificateEvidencePath -Value $certificateEvidence
$certificateRiskRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $certificateEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $certificateRiskRejected = $true
}
if (-not $certificateRiskRejected) {
    throw 'The assurance gate allowed an expiring certificate state.'
}

$incompleteEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$incompleteEvidence['drift'].Remove('identity') | Out-Null
Set-AssuranceEvidenceIntegrity -Evidence $incompleteEvidence
Write-JsonFile -Path $incompleteEvidencePath -Value $incompleteEvidence
$incompleteEvidenceRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $incompleteEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $incompleteEvidenceRejected = $true
}
if (-not $incompleteEvidenceRejected) {
    throw 'The assurance gate allowed incomplete drift evidence.'
}

$staleEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleCollectedAt = [DateTimeOffset]::UtcNow.AddMinutes(-120)
$staleEvidence['collectedAtUtc'] = $staleCollectedAt.ToString('o')
$staleEvidence['schedule']['nextReviewDueAtUtc'] = $staleCollectedAt.AddMinutes(60).ToString('o')
Set-AssuranceEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $staleEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'The assurance gate allowed stale evidence.'
}

$nonFullEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$nonFullEvidence['traffic']['observedTrafficPercent'] = 99
Set-AssuranceEvidenceIntegrity -Evidence $nonFullEvidence
Write-JsonFile -Path $nonFullEvidencePath -Value $nonFullEvidence
$nonFullTrafficRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $nonFullEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $nonFullTrafficRejected = $true
}
if (-not $nonFullTrafficRejected) {
    throw 'The assurance gate allowed less than 100 percent observed traffic.'
}

$decisionEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$decisionEvidence['decision']['reacceptanceRequired'] = $true
$decisionEvidence['decision']['requiredAction'] = 'reaccept-before-continuing'
Set-AssuranceEvidenceIntegrity -Evidence $decisionEvidence
Write-JsonFile -Path $decisionEvidencePath -Value $decisionEvidence
$decisionMismatchRejected = $false
try {
    $arguments = $gateArguments.Clone()
    $arguments.EvidencePath = $decisionEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @arguments | Out-Null
}
catch {
    $decisionMismatchRejected = $true
}
if (-not $decisionMismatchRejected) {
    throw 'The assurance gate allowed a decision inconsistent with clear drift signals.'
}

$originalEvidence = [System.IO.File]::ReadAllText($assuranceEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['driftEvidenceReference'] = 'TAMPERED-DRIFT-EVIDENCE'
    Write-JsonFile -Path $assuranceEvidencePath -Value $tamperedEvidence
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @gateArguments | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($assuranceEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The assurance gate allowed tampered periodic evidence.'
}

$originalAcceptedEvidence = [System.IO.File]::ReadAllText($acceptedEvidencePath)
$acceptedBaselineTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($acceptedEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @gateArguments | Out-Null
    }
    catch {
        $acceptedBaselineTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($acceptedEvidencePath, $originalAcceptedEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $acceptedBaselineTamperingRejected) {
    throw 'The assurance gate allowed a changed steady-state acceptance baseline.'
}

& (Join-Path $PSScriptRoot 'test-production-assurance-gate.ps1') @gateArguments | Out-Null
Write-Host 'Continuous production assurance and drift detection contract passed.'
