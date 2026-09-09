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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $repoRoot '.shieldward/production-traffic-contract'
$stagingEvidencePath = Join-Path $testRoot 'staging-evidence.json'
$initialPlanDirectory = Join-Path $testRoot 'initial-plan'
$initialPlanPath = Join-Path $initialPlanDirectory 'installation.json'
$baselinePath = Join-Path $testRoot 'production-baseline.json'
$trafficPlanDirectory = Join-Path $testRoot 'traffic-plan'
$trafficPlanPath = Join-Path $trafficPlanDirectory 'activation.json'
$candidateControlPlane = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane@sha256:' + ('1' * 64)
$candidateEdge = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge@sha256:' + ('2' * 64)
$policyVersion = 'sha256:' + ('5' * 64)

$checks = [ordered]@{
    healthStatus = 'ok'
    readyStatus = 'ready'
    runtimeVersion = '1.0.0'
    policyVersion = $policyVersion
    defaultDenyStatus = 403
    protectedRouteStatus = 401
}
$stagingEvidence = [ordered]@{
    schemaVersion = 1
    environment = 'staging'
    collectedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    kubernetesContext = 'staging-contract'
    namespace = 'shieldward'
    releaseVersion = '1.0.0'
    sourceTag = 'v1.0.0'
    images = [ordered]@{
        controlPlane = $candidateControlPlane
        edge = $candidateEdge
    }
    checks = [ordered]@{
        controlPlaneRuntimeVersion = '1.0.0'
        steadyState = $checks
        controlPlaneOutage = $checks
        recovery = $checks
    }
    deployments = @(
        [ordered]@{
            name = 'shieldward-control-plane'
            image = $candidateControlPlane
            desiredReplicas = 2
            availableReplicas = 2
            conditions = @([ordered]@{ type = 'Available'; status = 'True' })
        }
        [ordered]@{
            name = 'shieldward-edge'
            image = $candidateEdge
            desiredReplicas = 1
            availableReplicas = 1
            conditions = @([ordered]@{ type = 'Available'; status = 'True' })
        }
    )
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
[System.IO.File]::WriteAllText(
    $stagingEvidencePath,
    (($stagingEvidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot 'new-initial-production-plan.ps1') `
    -StagingEvidencePath $stagingEvidencePath `
    -ProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-001' `
    -ApprovalOwner 'Release Owner' `
    -RemovalAuthority 'Incident Commander' `
    -TrafficController 'Production Gateway' `
    -RemovalProcedureReference 'RUNBOOK-REMOVE-001' `
    -OutputDirectory $initialPlanDirectory `
    -Force | Out-Null
& (Join-Path $PSScriptRoot 'approve-initial-production-plan.ps1') `
    -PlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Release Owner' `
    -ApprovalStatement 'APPROVE INITIAL INSTALL CHG-TEST-001 FOR production-contract WITH TRAFFIC DISABLED' | Out-Null

$initialPlan = Get-Content -Raw -LiteralPath $initialPlanPath | ConvertFrom-Json
$initialPlanHash = (Get-FileHash -LiteralPath $initialPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$initialPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $initialPlanPath).Replace('\', '/')
$deployments = @(
    [ordered]@{
        name = 'shieldward-control-plane'
        image = $candidateControlPlane
        desiredReplicas = 2
        availableReplicas = 2
        observedGeneration = 3
    }
    [ordered]@{
        name = 'shieldward-edge'
        image = $candidateEdge
        desiredReplicas = 1
        availableReplicas = 1
        observedGeneration = 2
    }
)
$services = @(
    [ordered]@{
        name = 'shieldward-control-plane'
        type = 'ClusterIP'
        clusterIP = '10.96.0.10'
        externalIPCount = 0
        loadBalancerIngressCount = 0
    }
    [ordered]@{
        name = 'shieldward-edge'
        type = 'ClusterIP'
        clusterIP = '10.96.0.11'
        externalIPCount = 0
        loadBalancerIngressCount = 0
    }
)
$deploymentSummary = @($deployments | ForEach-Object {
    "$($_.name)|$($_.image)|$($_.desiredReplicas)|$($_.availableReplicas)|$($_.observedGeneration)"
}) -join ';'
$serviceSummary = @($services | ForEach-Object {
    "$($_.name)|$($_.type)|$($_.clusterIP)|$($_.externalIPCount)|$($_.loadBalancerIngressCount)"
}) -join ';'
$baselineCollectedAt = [DateTimeOffset]::UtcNow
$baselineIntegrity = [ordered]@{
    initialPlanSha256 = $initialPlanHash
    collectedAtUtc = $baselineCollectedAt.ToUniversalTime().ToString('o')
    productionContext = 'production-contract'
    namespace = 'shieldward'
    releaseVersion = '1.0.0'
    controlPlaneImage = $candidateControlPlane
    edgeImage = $candidateEdge
    trafficState = 'disabled'
    trafficController = 'Production Gateway'
    trafficIsolationEvidenceReference = 'TRAFFIC-ISOLATION-001'
    acceptanceEvidenceReference = 'ACCEPTANCE-001'
    removalProcedureReference = 'RUNBOOK-REMOVE-001'
    removalDrillEvidenceReference = 'REMOVAL-DRILL-001'
    edgeServerName = 'shieldward-edge.shieldward.svc.cluster.local'
    controlPlaneRuntimeVersion = '1.0.0'
    policyVersion = $policyVersion
    deploymentSummary = $deploymentSummary
    serviceSummary = $serviceSummary
}
$baseline = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'initial-baseline'
    state = 'candidate-ready-traffic-disabled'
    collectedAtUtc = $baselineCollectedAt.ToString('o')
    kubernetesContext = 'production-contract'
    namespace = 'shieldward'
    initialPlan = [ordered]@{
        relativePath = $initialPlanRelativePath
        sha256 = $initialPlanHash
        changeId = 'CHG-TEST-001'
        integrityDigest = [string]$initialPlan.integrityDigest
    }
    releaseVersion = '1.0.0'
    sourceTag = 'v1.0.0'
    images = [ordered]@{
        controlPlane = $candidateControlPlane
        edge = $candidateEdge
    }
    traffic = [ordered]@{
        state = 'disabled'
        controller = 'Production Gateway'
        isolationEvidenceReference = 'TRAFFIC-ISOLATION-001'
        externallyEnforced = $true
    }
    acceptance = [ordered]@{
        externalEvidenceReference = 'ACCEPTANCE-001'
        removalProcedureReference = 'RUNBOOK-REMOVE-001'
        removalDrillEvidenceReference = 'REMOVAL-DRILL-001'
        edgeServerName = 'shieldward-edge.shieldward.svc.cluster.local'
        controlPlaneRuntimeVersion = '1.0.0'
        edge = $checks
    }
    deployments = $deployments
    services = $services
    integrityDigest = Get-Sha256Text -Text ($baselineIntegrity | ConvertTo-Json -Depth 4 -Compress)
}
[System.IO.File]::WriteAllText(
    $baselinePath,
    (($baseline | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot 'test-production-baseline-evidence.ps1') `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' | Out-Null

$freshBaselineText = [System.IO.File]::ReadAllText($baselinePath)
$staleBaselineRejected = $false
try {
    $staleCollectedAt = [DateTimeOffset]::UtcNow.AddMinutes(-120)
    $staleBaseline = $freshBaselineText | ConvertFrom-Json -AsHashtable
    $staleBaseline['collectedAtUtc'] = $staleCollectedAt.ToString('o')
    $staleIntegrity = [ordered]@{}
    foreach ($entry in $baselineIntegrity.GetEnumerator()) {
        $staleIntegrity[$entry.Key] = $entry.Value
    }
    $staleIntegrity['collectedAtUtc'] = $staleCollectedAt.ToUniversalTime().ToString('o')
    $staleBaseline['integrityDigest'] = Get-Sha256Text -Text (
        $staleIntegrity | ConvertTo-Json -Depth 4 -Compress
    )
    [System.IO.File]::WriteAllText(
        $baselinePath,
        (($staleBaseline | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'new-production-traffic-plan.ps1') `
            -BaselineEvidencePath $baselinePath `
            -InitialPlanPath $initialPlanPath `
            -StagingEvidencePath $stagingEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -ChangeId 'CHG-TEST-STALE' `
            -ApprovalOwner 'Traffic Owner' `
            -MaxBaselineAgeMinutes 60 `
            -OutputDirectory (Join-Path $testRoot 'stale-plan') `
            -Force | Out-Null
    }
    catch {
        $staleBaselineRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $baselinePath,
        $freshBaselineText,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $staleBaselineRejected) {
    throw 'The production traffic contract accepted stale baseline evidence.'
}

& (Join-Path $PSScriptRoot 'new-production-traffic-plan.ps1') `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-002' `
    -ApprovalOwner 'Traffic Owner' `
    -CanaryPercent 1 `
    -ObservationMinutes 15 `
    -MaxBaselineAgeMinutes 60 `
    -OutputDirectory $trafficPlanDirectory `
    -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
    -PlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-traffic-plan.ps1') `
        -PlanPath $trafficPlanPath `
        -BaselineEvidencePath $baselinePath `
        -InitialPlanPath $initialPlanPath `
        -StagingEvidencePath $stagingEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Traffic Owner' `
        -ApprovalStatement 'APPROVE ALL PRODUCTION TRAFFIC' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The production traffic contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-traffic-plan.ps1') `
    -PlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Traffic Owner' `
    -ApprovalStatement 'APPROVE 1% CANARY CHG-TEST-002 FOR production-contract RELEASE 1.0.0' | Out-Null

& (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
    -PlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($trafficPlanPath)
$trafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['requestedState'] = 'full'
    [System.IO.File]::WriteAllText(
        $trafficPlanPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
            -PlanPath $trafficPlanPath `
            -BaselineEvidencePath $baselinePath `
            -InitialPlanPath $initialPlanPath `
            -StagingEvidencePath $stagingEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $trafficTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $trafficPlanPath,
        $originalPlan,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $trafficTamperingRejected) {
    throw 'The production traffic contract accepted full-traffic tampering.'
}

$originalBaseline = [System.IO.File]::ReadAllText($baselinePath)
$baselineTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($baselinePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
            -PlanPath $trafficPlanPath `
            -BaselineEvidencePath $baselinePath `
            -InitialPlanPath $initialPlanPath `
            -StagingEvidencePath $stagingEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $baselineTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $baselinePath,
        $originalBaseline,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $baselineTamperingRejected) {
    throw 'The production traffic contract accepted tampered baseline evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-traffic-plan.ps1') `
    -PlanPath $trafficPlanPath `
    -BaselineEvidencePath $baselinePath `
    -InitialPlanPath $initialPlanPath `
    -StagingEvidencePath $stagingEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Production baseline and traffic activation planning contract passed.'
