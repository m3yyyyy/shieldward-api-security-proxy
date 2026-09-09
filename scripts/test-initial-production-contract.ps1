[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $repoRoot '.shieldward/initial-production-contract'
$evidencePath = Join-Path $testRoot 'staging-evidence.json'
$planDirectory = Join-Path $testRoot 'plan'
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
$evidence = [ordered]@{
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
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

$sameContextRejected = $false
try {
    & (Join-Path $PSScriptRoot 'new-initial-production-plan.ps1') `
        -StagingEvidencePath $evidencePath `
        -ProductionContext 'staging-contract' `
        -ChangeId 'CHG-TEST-000' `
        -ApprovalOwner 'Release Owner' `
        -RemovalAuthority 'Incident Commander' `
        -TrafficController 'Production Gateway' `
        -RemovalProcedureReference 'CHG-TEST-000/removal' `
        -OutputDirectory $planDirectory `
        -Force | Out-Null
}
catch {
    $sameContextRejected = $true
}
if (-not $sameContextRejected) {
    throw 'The initial production contract accepted the staging context as production.'
}

& (Join-Path $PSScriptRoot 'new-initial-production-plan.ps1') `
    -StagingEvidencePath $evidencePath `
    -ProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-001' `
    -ApprovalOwner 'Release Owner' `
    -RemovalAuthority 'Incident Commander' `
    -TrafficController 'Production Gateway' `
    -RemovalProcedureReference 'CHG-TEST-001/removal' `
    -ObservationMinutes 15 `
    -OutputDirectory $planDirectory `
    -Force | Out-Null

$planPath = Join-Path $planDirectory 'installation.json'
& (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-initial-production-plan.ps1') `
        -PlanPath $planPath `
        -StagingEvidencePath $evidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Release Owner' `
        -ApprovalStatement 'APPROVE INITIAL INSTALL WITH TRAFFIC ENABLED' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The initial production contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-initial-production-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Release Owner' `
    -ApprovalStatement 'APPROVE INITIAL INSTALL CHG-TEST-001 FOR production-contract WITH TRAFFIC DISABLED' | Out-Null

& (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($planPath)
$trafficTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['desiredState'] = 'enabled'
    [System.IO.File]::WriteAllText(
        $planPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') `
            -PlanPath $planPath `
            -StagingEvidencePath $evidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $trafficTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $planPath,
        $originalPlan,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $trafficTamperingRejected) {
    throw 'The initial production contract accepted traffic-enable tampering.'
}

$originalEvidence = [System.IO.File]::ReadAllText($evidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($evidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') `
            -PlanPath $planPath `
            -StagingEvidencePath $evidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $evidencePath,
        $originalEvidence,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $evidenceTamperingRejected) {
    throw 'The initial production contract accepted tampered staging evidence.'
}

& (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Initial production installation planning contract passed.'
