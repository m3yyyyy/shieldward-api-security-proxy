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

function Set-CanaryEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $startedAt = [DateTimeOffset]$Evidence['observation']['startedAtUtc']
    $endedAt = [DateTimeOffset]$Evidence['observation']['endedAtUtc']
    $integrity = [ordered]@{
        trafficPlanSha256 = [string]$Evidence['trafficPlan']['sha256']
        trafficPlanIntegrityDigest = [string]$Evidence['trafficPlan']['integrityDigest']
        trafficPlanApprovalDigest = [string]$Evidence['trafficPlan']['approvalDigest']
        baselineEvidenceSha256 = [string]$Evidence['baselineEvidence']['sha256']
        collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
        productionContext = [string]$Evidence['productionContext']
        releaseVersion = [string]$Evidence['candidate']['version']
        sourceTag = [string]$Evidence['candidate']['sourceTag']
        controlPlaneImage = [string]$Evidence['candidate']['controlPlaneImage']
        edgeImage = [string]$Evidence['candidate']['edgeImage']
        policyVersion = [string]$Evidence['candidate']['policyVersion']
        trafficController = [string]$Evidence['traffic']['controller']
        observedCanaryPercent = [int]$Evidence['observation']['observedCanaryPercent']
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
$testRoot = Join-Path $repoRoot '.shieldward/production-expansion-contract'
$canaryEvidencePath = Join-Path $testRoot 'canary-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$expansionPlanDirectory = Join-Path $testRoot 'expansion-plan'
$expansionPlanPath = Join-Path $expansionPlanDirectory 'expansion.json'

& (Join-Path $PSScriptRoot 'test-production-traffic-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Move only the synthetic approval time into the past so the synthetic
# observation can cover the full approved window without sleeping.
$trafficPlan = Get-Content -Raw -LiteralPath $trafficPlanPath | ConvertFrom-Json -AsHashtable
$approvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-180)
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$trafficPlan['approval']['approvedAtUtc'] = $approvedAt.ToString('o')
$trafficPlan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$approvalInput = "$($trafficPlan['integrityDigest'])|$($trafficPlan['approval']['approvedBy'])|$approvedAtUnixSeconds|$($trafficPlan['approval']['approvalStatement'])"
$trafficPlan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
Write-JsonFile -Path $trafficPlanPath -Value $trafficPlan

& (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
    -PlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved `
    -ValidationPurpose PostActivationEvidence | Out-Null

$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
$trafficPlanObject = Get-Content -Raw -LiteralPath $trafficPlanPath | ConvertFrom-Json
$trafficPlanHash = (Get-FileHash -LiteralPath $trafficPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
$observationStart = [DateTimeOffset]::UtcNow.AddMinutes(-20)
$observationEnd = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$collectedAt = [DateTimeOffset]::UtcNow
$canaryEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'initial-canary-observation'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    trafficPlan = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $trafficPlanPath).Replace('\', '/')
        sha256 = $trafficPlanHash
        integrityDigest = [string]$trafficPlanObject.integrityDigest
        approvalDigest = [string]$trafficPlanObject.approval.approvalDigest
        changeId = [string]$trafficPlanObject.changeId
    }
    baselineEvidence = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $baselinePath).Replace('\', '/')
        sha256 = $baselineHash
        integrityDigest = [string]$baseline.integrityDigest
    }
    candidate = [ordered]@{
        version = [string]$trafficPlanObject.candidate.version
        sourceTag = [string]$trafficPlanObject.candidate.sourceTag
        controlPlaneImage = [string]$trafficPlanObject.candidate.controlPlaneImage
        edgeImage = [string]$trafficPlanObject.candidate.edgeImage
        policyVersion = [string]$trafficPlanObject.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$trafficPlanObject.traffic.controller
        externallyEnforced = $true
    }
    observation = [ordered]@{
        observedCanaryPercent = [int]$trafficPlanObject.traffic.canaryPercent
        startedAtUtc = $observationStart.ToString('o')
        endedAtUtc = $observationEnd.ToString('o')
        requiredMinutes = [int]$trafficPlanObject.observationMinutes
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
        trafficChangeReference = 'TRAFFIC-CHANGE-001'
        monitoringEvidenceReference = 'MONITORING-001'
        reviewedBy = 'Canary Reviewer'
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    rollback = [ordered]@{
        mode = [string]$trafficPlanObject.rollback.mode
        targetState = [string]$trafficPlanObject.rollback.targetState
        authority = [string]$trafficPlanObject.rollback.authority
        procedureReference = [string]$trafficPlanObject.rollback.procedureReference
    }
    integrityDigest = ''
}
$canaryHashtable = $canaryEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-CanaryEvidenceIntegrity -Evidence $canaryHashtable
Write-JsonFile -Path $canaryEvidencePath -Value $canaryHashtable

& (Join-Path $PSScriptRoot 'test-production-canary-evidence.ps1') `
    -EvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' | Out-Null

$unknownEvidence = $canaryHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['signals']['functional'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
Set-CanaryEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownCanaryRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-expansion-plan.ps1') `
        -CanaryEvidencePath $unknownEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-UNKNOWN' `
        -ApprovalOwner 'Expansion Owner' `
        -TargetPercent 25 `
        -OutputDirectory (Join-Path $testRoot 'unknown-plan') `
        -Force | Out-Null
}
catch {
    $unknownCanaryRejected = $true
}
if (-not $unknownCanaryRejected) {
    throw 'The production expansion contract accepted unknown canary signals.'
}

$staleEvidence = $canaryHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleStart = [DateTimeOffset]::UtcNow.AddMinutes(-140)
$staleEnd = [DateTimeOffset]::UtcNow.AddMinutes(-125)
$staleEvidence['observation']['startedAtUtc'] = $staleStart.ToString('o')
$staleEvidence['observation']['endedAtUtc'] = $staleEnd.ToString('o')
$staleEvidence['collectedAtUtc'] = [DateTimeOffset]::UtcNow.AddMinutes(-120).ToString('o')
Set-CanaryEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-expansion-plan.ps1') `
        -CanaryEvidencePath $staleEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-STALE' `
        -ApprovalOwner 'Expansion Owner' `
        -TargetPercent 25 `
        -MaxEvidenceAgeMinutes 60 `
        -OutputDirectory (Join-Path $testRoot 'stale-plan') `
        -Force | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'The production expansion contract accepted stale canary evidence.'
}

& (Join-Path $PSScriptRoot 'new-production-expansion-plan.ps1') `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-003' `
    -ApprovalOwner 'Expansion Owner' `
    -TargetPercent 25 `
    -ObservationMinutes 15 `
    -MaxEvidenceAgeMinutes 60 `
    -OutputDirectory $expansionPlanDirectory `
    -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') `
    -PlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-expansion-plan.ps1') `
        -PlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Expansion Owner' `
        -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The production expansion contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-expansion-plan.ps1') `
    -PlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Expansion Owner' `
    -ApprovalStatement 'APPROVE EXPANSION TO 25% CHG-TEST-003 FOR production-contract RELEASE 1.0.0' | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($expansionPlanPath)
$fullTrafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 100
    Write-JsonFile -Path $expansionPlanPath -Value $tamperedPlan
    try {
        & (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') `
            -PlanPath $expansionPlanPath `
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
    [System.IO.File]::WriteAllText($expansionPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $fullTrafficTamperingRejected) {
    throw 'The production expansion contract accepted full-traffic tampering.'
}

$originalEvidence = [System.IO.File]::ReadAllText($canaryEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($canaryEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') `
            -PlanPath $expansionPlanPath `
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
    [System.IO.File]::WriteAllText($canaryEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The production expansion contract accepted tampered canary evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') `
    -PlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Production canary evidence and first expansion planning contract passed.'
