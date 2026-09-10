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

function Set-FullTrafficEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $startedAt = [DateTimeOffset]$Evidence['observation']['startedAtUtc']
    $endedAt = [DateTimeOffset]$Evidence['observation']['endedAtUtc']
    $integrity = [ordered]@{
        finalExpansionPlanSha256 = [string]$Evidence['finalExpansionPlan']['sha256']
        finalExpansionPlanIntegrityDigest = [string]$Evidence['finalExpansionPlan']['integrityDigest']
        finalExpansionPlanApprovalDigest = [string]$Evidence['finalExpansionPlan']['approvalDigest']
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        productionContext = [string]$Evidence['productionContext']
        releaseVersion = [string]$Evidence['candidate']['version']
        sourceTag = [string]$Evidence['candidate']['sourceTag']
        controlPlaneImage = [string]$Evidence['candidate']['controlPlaneImage']
        edgeImage = [string]$Evidence['candidate']['edgeImage']
        policyVersion = [string]$Evidence['candidate']['policyVersion']
        trafficController = [string]$Evidence['traffic']['controller']
        previousTrafficPercent = [int]$Evidence['observation']['previousTrafficPercent']
        observedTrafficPercent = [int]$Evidence['observation']['observedTrafficPercent']
        observationStartedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        observationEndedAtUtc = $endedAt.ToUniversalTime().ToString('o')
        requiredObservationMinutes = [int]$Evidence['observation']['requiredMinutes']
        errorBudgetStatus = [string]$Evidence['signals']['errorBudget']
        alertStatus = [string]$Evidence['signals']['alerts']
        functionalStatus = [string]$Evidence['signals']['functional']
        dependencyStatus = [string]$Evidence['signals']['dependencies']
        operationalStatus = [string]$Evidence['signals']['operations']
        capacityStatus = [string]$Evidence['signals']['capacity']
        securityStatus = [string]$Evidence['signals']['security']
        trafficChangeReference = [string]$Evidence['externalEvidence']['trafficChangeReference']
        monitoringEvidenceReference = [string]$Evidence['externalEvidence']['monitoringEvidenceReference']
        reviewedBy = [string]$Evidence['externalEvidence']['reviewedBy']
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
$testRoot = Join-Path $repoRoot '.shieldward/production-steady-state-contract'
$evidencePath = Join-Path $testRoot 'full-traffic-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$failedEvidencePath = Join-Path $testRoot 'failed-evidence.json'
$incompleteEvidencePath = Join-Path $testRoot 'incomplete-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$nonFullEvidencePath = Join-Path $testRoot 'non-full-evidence.json'
$unenforcedEvidencePath = Join-Path $testRoot 'unenforced-evidence.json'

& (Join-Path $PSScriptRoot 'test-production-final-expansion-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Put only the synthetic approval into the past so a complete full-traffic
# observation can be represented without waiting or contacting production.
$finalPlan = Get-Content -Raw -LiteralPath $finalPlanPath | ConvertFrom-Json -AsHashtable
$generatedAt = [DateTimeOffset]::UtcNow.AddMinutes(-301)
$approvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-300)
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$finalPlan['generatedAtUtc'] = $generatedAt.ToString('o')
$finalPlan['approval']['approvedAtUtc'] = $approvedAt.ToString('o')
$finalPlan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$approvalInput = "$($finalPlan['integrityDigest'])|$($finalPlan['approval']['approvedBy'])|$approvedAtUnixSeconds|$($finalPlan['approval']['approvalStatement'])"
$finalPlan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
Write-JsonFile -Path $finalPlanPath -Value $finalPlan

$chainArguments = @{
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
$finalPlanValidationArguments = $chainArguments.Clone()
$finalPlanValidationArguments.Remove('FinalExpansionPlanPath') | Out-Null
$finalPlanValidationArguments.PlanPath = $finalPlanPath
$finalPlanValidationArguments.RequiredState = 'Approved'
$finalPlanValidationArguments.ValidationPurpose = 'PostExpansionEvidence'
& (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @finalPlanValidationArguments | Out-Null

$planObject = Get-Content -Raw -LiteralPath $finalPlanPath | ConvertFrom-Json
$planHash = (Get-FileHash -LiteralPath $finalPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$observationStart = [DateTimeOffset]::UtcNow.AddMinutes(-20)
$observationEnd = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$collectedAt = [DateTimeOffset]::UtcNow
$fullTrafficEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'full-traffic-observation'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    finalExpansionPlan = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $finalPlanPath).Replace('\', '/')
        sha256 = $planHash
        integrityDigest = [string]$planObject.integrityDigest
        approvalDigest = [string]$planObject.approval.approvalDigest
        changeId = [string]$planObject.changeId
    }
    candidate = [ordered]@{
        version = [string]$planObject.candidate.version
        sourceTag = [string]$planObject.candidate.sourceTag
        controlPlaneImage = [string]$planObject.candidate.controlPlaneImage
        edgeImage = [string]$planObject.candidate.edgeImage
        policyVersion = [string]$planObject.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$planObject.traffic.controller
        externallyEnforced = $true
    }
    observation = [ordered]@{
        previousTrafficPercent = 75
        observedTrafficPercent = 100
        startedAtUtc = $observationStart.ToString('o')
        endedAtUtc = $observationEnd.ToString('o')
        requiredMinutes = [int]$planObject.observationMinutes
        observedMinutes = 15
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
    externalEvidence = [ordered]@{
        trafficChangeReference = 'TRAFFIC-CHANGE-005'
        monitoringEvidenceReference = 'MONITORING-005'
        reviewedBy = 'Steady State Reviewer'
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    rollback = [ordered]@{
        mode = [string]$planObject.rollback.mode
        targetPercent = [int]$planObject.rollback.targetPercent
        emergencyTargetPercent = [int]$planObject.rollback.emergencyTargetPercent
        authority = [string]$planObject.rollback.authority
        procedureReference = [string]$planObject.rollback.procedureReference
    }
    integrityDigest = ''
}
$evidenceHashtable = $fullTrafficEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-FullTrafficEvidenceIntegrity -Evidence $evidenceHashtable
Write-JsonFile -Path $evidencePath -Value $evidenceHashtable

$acceptanceArguments = $chainArguments.Clone()
$acceptanceArguments.EvidencePath = $evidencePath
$acceptanceArguments.MaxEvidenceAgeMinutes = 60
$evidenceValidationArguments = $chainArguments.Clone()
$evidenceValidationArguments.EvidencePath = $evidencePath
& (Join-Path $PSScriptRoot 'test-production-full-traffic-evidence.ps1') @evidenceValidationArguments | Out-Null
& (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @acceptanceArguments | Out-Null

$unknownEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['signals']['security'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
Set-FullTrafficEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownFullTrafficRejected = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $unknownEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $unknownFullTrafficRejected = $true
}
if (-not $unknownFullTrafficRejected) {
    throw 'Steady-state acceptance allowed unknown full-traffic signals.'
}

$failedEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$failedEvidence['signals']['capacity'] = 'degraded'
$failedEvidence['outcome'] = 'failed'
Set-FullTrafficEvidenceIntegrity -Evidence $failedEvidence
Write-JsonFile -Path $failedEvidencePath -Value $failedEvidence
$failedFullTrafficRejected = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $failedEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $failedFullTrafficRejected = $true
}
if (-not $failedFullTrafficRejected) {
    throw 'Steady-state acceptance allowed failed full-traffic signals.'
}

$incompleteEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$incompleteEvidence['signals'].Remove('security') | Out-Null
Set-FullTrafficEvidenceIntegrity -Evidence $incompleteEvidence
Write-JsonFile -Path $incompleteEvidencePath -Value $incompleteEvidence
$incompleteEvidenceRejected = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $incompleteEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $incompleteEvidenceRejected = $true
}
if (-not $incompleteEvidenceRejected) {
    throw 'Steady-state acceptance allowed incomplete full-traffic evidence.'
}

$staleEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleStart = [DateTimeOffset]::UtcNow.AddMinutes(-160)
$staleEnd = [DateTimeOffset]::UtcNow.AddMinutes(-145)
$staleEvidence['observation']['startedAtUtc'] = $staleStart.ToString('o')
$staleEvidence['observation']['endedAtUtc'] = $staleEnd.ToString('o')
$staleEvidence['collectedAtUtc'] = [DateTimeOffset]::UtcNow.AddMinutes(-140).ToString('o')
Set-FullTrafficEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $staleEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'Steady-state acceptance allowed stale full-traffic evidence.'
}

$nonFullEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$nonFullEvidence['observation']['observedTrafficPercent'] = 99
Set-FullTrafficEvidenceIntegrity -Evidence $nonFullEvidence
Write-JsonFile -Path $nonFullEvidencePath -Value $nonFullEvidence
$nonFullTrafficRejected = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $nonFullEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $nonFullTrafficRejected = $true
}
if (-not $nonFullTrafficRejected) {
    throw 'Steady-state acceptance allowed an observation below 100 percent traffic.'
}

$unenforcedEvidence = $evidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unenforcedEvidence['traffic']['externallyEnforced'] = $false
$unenforcedEvidence['checks']['trafficControllerExternallyEnforced'] = $false
Set-FullTrafficEvidenceIntegrity -Evidence $unenforcedEvidence
Write-JsonFile -Path $unenforcedEvidencePath -Value $unenforcedEvidence
$externalEnforcementRequired = $false
try {
    $arguments = $acceptanceArguments.Clone()
    $arguments.EvidencePath = $unenforcedEvidencePath
    & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @arguments | Out-Null
}
catch {
    $externalEnforcementRequired = $true
}
if (-not $externalEnforcementRequired) {
    throw 'Steady-state acceptance did not require external full-traffic enforcement.'
}

$originalEvidence = [System.IO.File]::ReadAllText($evidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['monitoringEvidenceReference'] = 'TAMPERED-MONITORING'
    Write-JsonFile -Path $evidencePath -Value $tamperedEvidence
    try {
        & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @acceptanceArguments | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($evidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Steady-state acceptance allowed tampered full-traffic evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($finalPlanPath)
$planTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($finalPlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @acceptanceArguments | Out-Null
    }
    catch {
        $planTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($finalPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) {
    throw 'Steady-state acceptance allowed a changed final expansion plan.'
}

& (Join-Path $PSScriptRoot 'test-production-steady-state-acceptance.ps1') @acceptanceArguments | Out-Null
Write-Host 'Production full-traffic evidence and steady-state acceptance contract passed.'
