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

function Set-SecondExpansionEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $startedAt = [DateTimeOffset]$Evidence['observation']['startedAtUtc']
    $endedAt = [DateTimeOffset]$Evidence['observation']['endedAtUtc']
    $integrity = [ordered]@{
        secondExpansionPlanSha256 = [string]$Evidence['secondExpansionPlan']['sha256']
        secondExpansionPlanIntegrityDigest = [string]$Evidence['secondExpansionPlan']['integrityDigest']
        secondExpansionPlanApprovalDigest = [string]$Evidence['secondExpansionPlan']['approvalDigest']
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
$testRoot = Join-Path $repoRoot '.shieldward/production-final-expansion-contract'
$secondEvidencePath = Join-Path $testRoot 'second-expansion-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$failedEvidencePath = Join-Path $testRoot 'failed-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$finalPlanDirectory = Join-Path $testRoot 'final-plan'
$finalPlanPath = Join-Path $finalPlanDirectory 'expansion.json'

& (Join-Path $PSScriptRoot 'test-production-second-expansion-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Move only the synthetic second-expansion approval time into the past so the
# synthetic 75 percent observation can cover the full window without sleeping.
$secondPlan = Get-Content -Raw -LiteralPath $secondPlanPath | ConvertFrom-Json -AsHashtable
$approvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-180)
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$secondPlan['approval']['approvedAtUtc'] = $approvedAt.ToString('o')
$secondPlan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$approvalInput = "$($secondPlan['integrityDigest'])|$($secondPlan['approval']['approvedBy'])|$approvedAtUnixSeconds|$($secondPlan['approval']['approvalStatement'])"
$secondPlan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
Write-JsonFile -Path $secondPlanPath -Value $secondPlan

$secondPlanValidationArguments = @{
    PlanPath = $secondPlanPath
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
    RequiredState = 'Approved'
    ValidationPurpose = 'PostExpansionEvidence'
}
& (Join-Path $PSScriptRoot 'test-production-second-expansion-plan.ps1') @secondPlanValidationArguments | Out-Null

$planObject = Get-Content -Raw -LiteralPath $secondPlanPath | ConvertFrom-Json
$planHash = (Get-FileHash -LiteralPath $secondPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$observationStart = [DateTimeOffset]::UtcNow.AddMinutes(-20)
$observationEnd = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$collectedAt = [DateTimeOffset]::UtcNow
$secondEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'second-expansion-observation'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    secondExpansionPlan = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $secondPlanPath).Replace('\', '/')
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
        previousTrafficPercent = [int]$planObject.traffic.currentPercent
        observedTrafficPercent = [int]$planObject.traffic.targetPercent
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
    }
    externalEvidence = [ordered]@{
        trafficChangeReference = 'TRAFFIC-CHANGE-004'
        monitoringEvidenceReference = 'MONITORING-004'
        reviewedBy = 'Final Expansion Reviewer'
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
$secondEvidenceHashtable = $secondEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-SecondExpansionEvidenceIntegrity -Evidence $secondEvidenceHashtable
Write-JsonFile -Path $secondEvidencePath -Value $secondEvidenceHashtable

$secondEvidenceValidationArguments = @{
    EvidencePath = $secondEvidencePath
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
& (Join-Path $PSScriptRoot 'test-production-second-expansion-evidence.ps1') @secondEvidenceValidationArguments | Out-Null

$finalPlanBaseArguments = @{
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
    ApprovalOwner = 'Final Expansion Owner'
    TargetPercent = 100
    ObservationMinutes = 15
    MaxEvidenceAgeMinutes = 60
    Force = $true
}

$unknownEvidence = $secondEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['signals']['functional'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
Set-SecondExpansionEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownSecondExpansionRejected = $false
try {
    $unknownPlanArguments = $finalPlanBaseArguments.Clone()
    $unknownPlanArguments.SecondExpansionEvidencePath = $unknownEvidencePath
    $unknownPlanArguments.ChangeId = 'CHG-TEST-UNKNOWN'
    $unknownPlanArguments.OutputDirectory = Join-Path $testRoot 'unknown-plan'
    & (Join-Path $PSScriptRoot 'new-production-final-expansion-plan.ps1') @unknownPlanArguments | Out-Null
}
catch {
    $unknownSecondExpansionRejected = $true
}
if (-not $unknownSecondExpansionRejected) {
    throw 'The final expansion contract accepted unknown second-expansion signals.'
}

$failedEvidence = $secondEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$failedEvidence['signals']['alerts'] = 'firing'
$failedEvidence['outcome'] = 'failed'
Set-SecondExpansionEvidenceIntegrity -Evidence $failedEvidence
Write-JsonFile -Path $failedEvidencePath -Value $failedEvidence
$failedSecondExpansionRejected = $false
try {
    $failedPlanArguments = $finalPlanBaseArguments.Clone()
    $failedPlanArguments.SecondExpansionEvidencePath = $failedEvidencePath
    $failedPlanArguments.ChangeId = 'CHG-TEST-FAILED'
    $failedPlanArguments.OutputDirectory = Join-Path $testRoot 'failed-plan'
    & (Join-Path $PSScriptRoot 'new-production-final-expansion-plan.ps1') @failedPlanArguments | Out-Null
}
catch {
    $failedSecondExpansionRejected = $true
}
if (-not $failedSecondExpansionRejected) {
    throw 'The final expansion contract accepted failed second-expansion signals.'
}

$staleEvidence = $secondEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleStart = [DateTimeOffset]::UtcNow.AddMinutes(-140)
$staleEnd = [DateTimeOffset]::UtcNow.AddMinutes(-125)
$staleEvidence['observation']['startedAtUtc'] = $staleStart.ToString('o')
$staleEvidence['observation']['endedAtUtc'] = $staleEnd.ToString('o')
$staleEvidence['collectedAtUtc'] = [DateTimeOffset]::UtcNow.AddMinutes(-120).ToString('o')
Set-SecondExpansionEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    $stalePlanArguments = $finalPlanBaseArguments.Clone()
    $stalePlanArguments.SecondExpansionEvidencePath = $staleEvidencePath
    $stalePlanArguments.ChangeId = 'CHG-TEST-STALE'
    $stalePlanArguments.OutputDirectory = Join-Path $testRoot 'stale-plan'
    & (Join-Path $PSScriptRoot 'new-production-final-expansion-plan.ps1') @stalePlanArguments | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'The final expansion contract accepted stale second-expansion evidence.'
}

$nonFullTargetRejected = $false
try {
    $nonFullPlanArguments = $finalPlanBaseArguments.Clone()
    $nonFullPlanArguments.SecondExpansionEvidencePath = $secondEvidencePath
    $nonFullPlanArguments.ChangeId = 'CHG-TEST-NON-FULL'
    $nonFullPlanArguments.TargetPercent = 99
    $nonFullPlanArguments.OutputDirectory = Join-Path $testRoot 'non-full-plan'
    & (Join-Path $PSScriptRoot 'new-production-final-expansion-plan.ps1') @nonFullPlanArguments | Out-Null
}
catch {
    $nonFullTargetRejected = $true
}
if (-not $nonFullTargetRejected) {
    throw 'The final expansion contract accepted a target other than exactly 100 percent.'
}

$finalPlanArguments = $finalPlanBaseArguments.Clone()
$finalPlanArguments.SecondExpansionEvidencePath = $secondEvidencePath
$finalPlanArguments.ChangeId = 'CHG-TEST-006'
$finalPlanArguments.OutputDirectory = $finalPlanDirectory
& (Join-Path $PSScriptRoot 'new-production-final-expansion-plan.ps1') @finalPlanArguments | Out-Null

$finalPlanValidationArguments = $secondEvidenceValidationArguments.Clone()
$finalPlanValidationArguments.Remove('EvidencePath') | Out-Null
$finalPlanValidationArguments.PlanPath = $finalPlanPath
$finalPlanValidationArguments.SecondExpansionEvidencePath = $secondEvidencePath
$finalPlanValidationArguments.RequiredState = 'Pending'
& (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @finalPlanValidationArguments | Out-Null

$invalidApprovalRejected = $false
try {
    $invalidApprovalArguments = $finalPlanValidationArguments.Clone()
    $invalidApprovalArguments.Remove('RequiredState') | Out-Null
    $invalidApprovalArguments.ApprovedBy = 'Final Expansion Owner'
    $invalidApprovalArguments.ApprovalStatement = 'APPROVE EXPANSION TO 100% CHG-TEST-006 FOR production-contract RELEASE 1.0.0'
    & (Join-Path $PSScriptRoot 'approve-production-final-expansion-plan.ps1') @invalidApprovalArguments | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The final expansion contract accepted an invalid full-traffic approval statement.'
}

$approvalArguments = $finalPlanValidationArguments.Clone()
$approvalArguments.Remove('RequiredState') | Out-Null
$approvalArguments.ApprovedBy = 'Final Expansion Owner'
$approvalArguments.ApprovalStatement = 'APPROVE FINAL EXPANSION TO 100% CHG-TEST-006 FOR production-contract RELEASE 1.0.0'
& (Join-Path $PSScriptRoot 'approve-production-final-expansion-plan.ps1') @approvalArguments | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($finalPlanPath)
$fullTrafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 99
    Write-JsonFile -Path $finalPlanPath -Value $tamperedPlan
    try {
        $approvedValidationArguments = $finalPlanValidationArguments.Clone()
        $approvedValidationArguments.RequiredState = 'Approved'
        & (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @approvedValidationArguments | Out-Null
    }
    catch {
        $fullTrafficTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($finalPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $fullTrafficTamperingRejected) {
    throw 'The final expansion contract accepted a non-exact full-traffic target.'
}

$originalEvidence = [System.IO.File]::ReadAllText($secondEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($secondEvidencePath, ' ')
    try {
        $approvedValidationArguments = $finalPlanValidationArguments.Clone()
        $approvedValidationArguments.RequiredState = 'Approved'
        & (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @approvedValidationArguments | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($secondEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The final expansion contract accepted tampered second-expansion evidence.'
}

$approvedValidationArguments = $finalPlanValidationArguments.Clone()
$approvedValidationArguments.RequiredState = 'Approved'
& (Join-Path $PSScriptRoot 'test-production-final-expansion-plan.ps1') @approvedValidationArguments | Out-Null

Write-Host 'Production second-expansion evidence and final expansion planning contract passed.'
