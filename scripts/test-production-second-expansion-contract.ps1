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

function Set-ProgressiveEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $startedAt = [DateTimeOffset]$Evidence['observation']['startedAtUtc']
    $endedAt = [DateTimeOffset]$Evidence['observation']['endedAtUtc']
    $integrity = [ordered]@{
        progressivePlanSha256 = [string]$Evidence['progressivePlan']['sha256']
        progressivePlanIntegrityDigest = [string]$Evidence['progressivePlan']['integrityDigest']
        progressivePlanApprovalDigest = [string]$Evidence['progressivePlan']['approvalDigest']
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
$testRoot = Join-Path $repoRoot '.shieldward/production-second-expansion-contract'
$progressiveEvidencePath = Join-Path $testRoot 'progressive-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$secondPlanDirectory = Join-Path $testRoot 'second-plan'
$secondPlanPath = Join-Path $secondPlanDirectory 'expansion.json'

& (Join-Path $PSScriptRoot 'test-production-progressive-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Move only the synthetic progressive approval time into the past so the
# synthetic observation can cover the full approved window without sleeping.
$progressivePlan = Get-Content -Raw -LiteralPath $progressivePlanPath | ConvertFrom-Json -AsHashtable
$approvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-180)
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$progressivePlan['approval']['approvedAtUtc'] = $approvedAt.ToString('o')
$progressivePlan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$approvalInput = "$($progressivePlan['integrityDigest'])|$($progressivePlan['approval']['approvedBy'])|$approvedAtUnixSeconds|$($progressivePlan['approval']['approvalStatement'])"
$progressivePlan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
Write-JsonFile -Path $progressivePlanPath -Value $progressivePlan

& (Join-Path $PSScriptRoot 'test-production-progressive-plan.ps1') `
    -PlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved `
    -ValidationPurpose PostExpansionEvidence | Out-Null

$planObject = Get-Content -Raw -LiteralPath $progressivePlanPath | ConvertFrom-Json
$planHash = (Get-FileHash -LiteralPath $progressivePlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$observationStart = [DateTimeOffset]::UtcNow.AddMinutes(-20)
$observationEnd = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$collectedAt = [DateTimeOffset]::UtcNow
$progressiveEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'progressive-expansion-observation'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    progressivePlan = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $progressivePlanPath).Replace('\', '/')
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
        trafficChangeReference = 'TRAFFIC-CHANGE-003'
        monitoringEvidenceReference = 'MONITORING-003'
        reviewedBy = 'Second Expansion Reviewer'
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
$progressiveEvidenceHashtable = $progressiveEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-ProgressiveEvidenceIntegrity -Evidence $progressiveEvidenceHashtable
Write-JsonFile -Path $progressiveEvidencePath -Value $progressiveEvidenceHashtable

& (Join-Path $PSScriptRoot 'test-production-progressive-evidence.ps1') `
    -EvidencePath $progressiveEvidencePath `
    -ProgressivePlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' | Out-Null

$unknownEvidence = $progressiveEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['signals']['functional'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
Set-ProgressiveEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownProgressiveRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-second-expansion-plan.ps1') `
        -ProgressiveEvidencePath $unknownEvidencePath `
        -ProgressivePlanPath $progressivePlanPath `
        -ExpansionEvidencePath $expansionEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-UNKNOWN' `
        -ApprovalOwner 'Second Expansion Owner' `
        -TargetPercent 75 `
        -OutputDirectory (Join-Path $testRoot 'unknown-plan') `
        -Force | Out-Null
}
catch {
    $unknownProgressiveRejected = $true
}
if (-not $unknownProgressiveRejected) {
    throw 'The second expansion contract accepted unknown progressive signals.'
}

$staleEvidence = $progressiveEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleStart = [DateTimeOffset]::UtcNow.AddMinutes(-140)
$staleEnd = [DateTimeOffset]::UtcNow.AddMinutes(-125)
$staleEvidence['observation']['startedAtUtc'] = $staleStart.ToString('o')
$staleEvidence['observation']['endedAtUtc'] = $staleEnd.ToString('o')
$staleEvidence['collectedAtUtc'] = [DateTimeOffset]::UtcNow.AddMinutes(-120).ToString('o')
Set-ProgressiveEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-second-expansion-plan.ps1') `
        -ProgressiveEvidencePath $staleEvidencePath `
        -ProgressivePlanPath $progressivePlanPath `
        -ExpansionEvidencePath $expansionEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-STALE' `
        -ApprovalOwner 'Second Expansion Owner' `
        -TargetPercent 75 `
        -MaxEvidenceAgeMinutes 60 `
        -OutputDirectory (Join-Path $testRoot 'stale-plan') `
        -Force | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'The second expansion contract accepted stale progressive evidence.'
}

& (Join-Path $PSScriptRoot 'new-production-second-expansion-plan.ps1') `
    -ProgressiveEvidencePath $progressiveEvidencePath `
    -ProgressivePlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-005' `
    -ApprovalOwner 'Second Expansion Owner' `
    -TargetPercent 75 `
    -ObservationMinutes 15 `
    -MaxEvidenceAgeMinutes 60 `
    -OutputDirectory $secondPlanDirectory `
    -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-second-expansion-plan.ps1') `
    -PlanPath $secondPlanPath `
    -ProgressiveEvidencePath $progressiveEvidencePath `
    -ProgressivePlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-second-expansion-plan.ps1') `
        -PlanPath $secondPlanPath `
        -ProgressiveEvidencePath $progressiveEvidencePath `
        -ProgressivePlanPath $progressivePlanPath `
        -ExpansionEvidencePath $expansionEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Second Expansion Owner' `
        -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The second expansion contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-second-expansion-plan.ps1') `
    -PlanPath $secondPlanPath `
    -ProgressiveEvidencePath $progressiveEvidencePath `
    -ProgressivePlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Second Expansion Owner' `
    -ApprovalStatement 'APPROVE EXPANSION TO 75% CHG-TEST-005 FOR production-contract RELEASE 1.0.0' | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($secondPlanPath)
$fullTrafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 100
    Write-JsonFile -Path $secondPlanPath -Value $tamperedPlan
    try {
        & (Join-Path $PSScriptRoot 'test-production-second-expansion-plan.ps1') `
            -PlanPath $secondPlanPath `
            -ProgressiveEvidencePath $progressiveEvidencePath `
            -ProgressivePlanPath $progressivePlanPath `
            -ExpansionEvidencePath $expansionEvidencePath `
            -ExpansionPlanPath $expansionPlanPath `
            -CanaryEvidencePath $canaryEvidencePath `
            -TrafficPlanPath $trafficPlanPath `
            -BaselineEvidencePath $baselinePath `
            -InitialPlanPath $initialPlanPath `
            -StagingEvidencePath $stagingEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $fullTrafficTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($secondPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $fullTrafficTamperingRejected) {
    throw 'The second expansion contract accepted full-traffic tampering.'
}

$originalEvidence = [System.IO.File]::ReadAllText($progressiveEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($progressiveEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-second-expansion-plan.ps1') `
            -PlanPath $secondPlanPath `
            -ProgressiveEvidencePath $progressiveEvidencePath `
            -ProgressivePlanPath $progressivePlanPath `
            -ExpansionEvidencePath $expansionEvidencePath `
            -ExpansionPlanPath $expansionPlanPath `
            -CanaryEvidencePath $canaryEvidencePath `
            -TrafficPlanPath $trafficPlanPath `
            -BaselineEvidencePath $baselinePath `
            -InitialPlanPath $initialPlanPath `
            -StagingEvidencePath $stagingEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($progressiveEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The second expansion contract accepted tampered progressive evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-second-expansion-plan.ps1') `
    -PlanPath $secondPlanPath `
    -ProgressiveEvidencePath $progressiveEvidencePath `
    -ProgressivePlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Production progressive evidence and second expansion planning contract passed.'
