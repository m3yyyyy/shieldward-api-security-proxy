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

function Set-ExpansionEvidenceIntegrity {
    param([Parameter(Mandatory)][hashtable]$Evidence)

    $collectedAt = [DateTimeOffset]$Evidence['collectedAtUtc']
    $startedAt = [DateTimeOffset]$Evidence['observation']['startedAtUtc']
    $endedAt = [DateTimeOffset]$Evidence['observation']['endedAtUtc']
    $integrity = [ordered]@{
        expansionPlanSha256 = [string]$Evidence['expansionPlan']['sha256']
        expansionPlanIntegrityDigest = [string]$Evidence['expansionPlan']['integrityDigest']
        expansionPlanApprovalDigest = [string]$Evidence['expansionPlan']['approvalDigest']
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
$testRoot = Join-Path $repoRoot '.shieldward/production-progressive-contract'
$expansionEvidencePath = Join-Path $testRoot 'expansion-evidence.json'
$unknownEvidencePath = Join-Path $testRoot 'unknown-evidence.json'
$staleEvidencePath = Join-Path $testRoot 'stale-evidence.json'
$progressivePlanDirectory = Join-Path $testRoot 'progressive-plan'
$progressivePlanPath = Join-Path $progressivePlanDirectory 'expansion.json'

& (Join-Path $PSScriptRoot 'test-production-expansion-contract.ps1') | Out-Null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Move only the synthetic first-expansion approval time into the past so the
# synthetic observation can cover the full approved window without sleeping.
$expansionPlan = Get-Content -Raw -LiteralPath $expansionPlanPath | ConvertFrom-Json -AsHashtable
$approvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-180)
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$expansionPlan['approval']['approvedAtUtc'] = $approvedAt.ToString('o')
$expansionPlan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$approvalInput = "$($expansionPlan['integrityDigest'])|$($expansionPlan['approval']['approvedBy'])|$approvedAtUnixSeconds|$($expansionPlan['approval']['approvalStatement'])"
$expansionPlan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
Write-JsonFile -Path $expansionPlanPath -Value $expansionPlan

& (Join-Path $PSScriptRoot 'test-production-expansion-plan.ps1') `
    -PlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved `
    -ValidationPurpose PostExpansionEvidence | Out-Null

$expansionPlanObject = Get-Content -Raw -LiteralPath $expansionPlanPath | ConvertFrom-Json
$expansionPlanHash = (Get-FileHash -LiteralPath $expansionPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$observationStart = [DateTimeOffset]::UtcNow.AddMinutes(-20)
$observationEnd = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$collectedAt = [DateTimeOffset]::UtcNow
$expansionEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'first-expansion-observation'
    outcome = 'passed'
    collectedAtUtc = $collectedAt.ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    expansionPlan = [ordered]@{
        relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $expansionPlanPath).Replace('\', '/')
        sha256 = $expansionPlanHash
        integrityDigest = [string]$expansionPlanObject.integrityDigest
        approvalDigest = [string]$expansionPlanObject.approval.approvalDigest
        changeId = [string]$expansionPlanObject.changeId
    }
    candidate = [ordered]@{
        version = [string]$expansionPlanObject.candidate.version
        sourceTag = [string]$expansionPlanObject.candidate.sourceTag
        controlPlaneImage = [string]$expansionPlanObject.candidate.controlPlaneImage
        edgeImage = [string]$expansionPlanObject.candidate.edgeImage
        policyVersion = [string]$expansionPlanObject.candidate.policyVersion
    }
    traffic = [ordered]@{
        controller = [string]$expansionPlanObject.traffic.controller
        externallyEnforced = $true
    }
    observation = [ordered]@{
        previousTrafficPercent = [int]$expansionPlanObject.traffic.currentPercent
        observedTrafficPercent = [int]$expansionPlanObject.traffic.targetPercent
        startedAtUtc = $observationStart.ToString('o')
        endedAtUtc = $observationEnd.ToString('o')
        requiredMinutes = [int]$expansionPlanObject.observationMinutes
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
        trafficChangeReference = 'TRAFFIC-CHANGE-002'
        monitoringEvidenceReference = 'MONITORING-002'
        reviewedBy = 'Progressive Reviewer'
    }
    checks = [ordered]@{
        liveClusterVerification = 'passed'
        trafficControllerExternallyEnforced = $true
    }
    rollback = [ordered]@{
        mode = [string]$expansionPlanObject.rollback.mode
        targetState = [string]$expansionPlanObject.rollback.targetState
        authority = [string]$expansionPlanObject.rollback.authority
        procedureReference = [string]$expansionPlanObject.rollback.procedureReference
    }
    integrityDigest = ''
}
$expansionEvidenceHashtable = $expansionEvidence | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
Set-ExpansionEvidenceIntegrity -Evidence $expansionEvidenceHashtable
Write-JsonFile -Path $expansionEvidencePath -Value $expansionEvidenceHashtable

& (Join-Path $PSScriptRoot 'test-production-expansion-evidence.ps1') `
    -EvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' | Out-Null

$unknownEvidence = $expansionEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$unknownEvidence['signals']['functional'] = 'unknown'
$unknownEvidence['outcome'] = 'unknown'
Set-ExpansionEvidenceIntegrity -Evidence $unknownEvidence
Write-JsonFile -Path $unknownEvidencePath -Value $unknownEvidence
$unknownExpansionRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-progressive-plan.ps1') `
        -ExpansionEvidencePath $unknownEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-UNKNOWN' `
        -ApprovalOwner 'Progressive Owner' `
        -TargetPercent 50 `
        -OutputDirectory (Join-Path $testRoot 'unknown-plan') `
        -Force | Out-Null
}
catch {
    $unknownExpansionRejected = $true
}
if (-not $unknownExpansionRejected) {
    throw 'The progressive expansion contract accepted unknown first-expansion signals.'
}

$staleEvidence = $expansionEvidenceHashtable | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
$staleStart = [DateTimeOffset]::UtcNow.AddMinutes(-140)
$staleEnd = [DateTimeOffset]::UtcNow.AddMinutes(-125)
$staleEvidence['observation']['startedAtUtc'] = $staleStart.ToString('o')
$staleEvidence['observation']['endedAtUtc'] = $staleEnd.ToString('o')
$staleEvidence['collectedAtUtc'] = [DateTimeOffset]::UtcNow.AddMinutes(-120).ToString('o')
Set-ExpansionEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-production-progressive-plan.ps1') `
        -ExpansionEvidencePath $staleEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId 'CHG-TEST-STALE' `
        -ApprovalOwner 'Progressive Owner' `
        -TargetPercent 50 `
        -MaxEvidenceAgeMinutes 60 `
        -OutputDirectory (Join-Path $testRoot 'stale-plan') `
        -Force | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'The progressive expansion contract accepted stale first-expansion evidence.'
}

& (Join-Path $PSScriptRoot 'new-production-progressive-plan.ps1') `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-004' `
    -ApprovalOwner 'Progressive Owner' `
    -TargetPercent 50 `
    -ObservationMinutes 15 `
    -MaxEvidenceAgeMinutes 60 `
    -OutputDirectory $progressivePlanDirectory `
    -Force | Out-Null

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
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-progressive-plan.ps1') `
        -PlanPath $progressivePlanPath `
        -ExpansionEvidencePath $expansionEvidencePath `
        -ExpansionPlanPath $expansionPlanPath `
        -CanaryEvidencePath $canaryEvidencePath `
        -TrafficPlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Progressive Owner' `
        -ApprovalStatement 'APPROVE FULL PRODUCTION TRAFFIC' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The progressive expansion contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-progressive-plan.ps1') `
    -PlanPath $progressivePlanPath `
    -ExpansionEvidencePath $expansionEvidencePath `
    -ExpansionPlanPath $expansionPlanPath `
    -CanaryEvidencePath $canaryEvidencePath `
    -TrafficPlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Progressive Owner' `
    -ApprovalStatement 'APPROVE EXPANSION TO 50% CHG-TEST-004 FOR production-contract RELEASE 1.0.0' | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($progressivePlanPath)
$fullTrafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 100
    Write-JsonFile -Path $progressivePlanPath -Value $tamperedPlan
    try {
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
            -RequiredState Approved | Out-Null
    }
    catch {
        $fullTrafficTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($progressivePlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $fullTrafficTamperingRejected) {
    throw 'The progressive expansion contract accepted full-traffic tampering.'
}

$originalEvidence = [System.IO.File]::ReadAllText($expansionEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($expansionEvidencePath, ' ')
    try {
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
            -RequiredState Approved | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($expansionEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The progressive expansion contract accepted tampered first-expansion evidence.'
}

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
    -RequiredState Approved | Out-Null

Write-Host 'Production first-expansion evidence and progressive planning contract passed.'
