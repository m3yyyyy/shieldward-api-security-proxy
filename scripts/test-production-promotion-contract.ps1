[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $repoRoot '.shieldward/promotion-contract'
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

& (Join-Path $PSScriptRoot 'new-production-promotion-plan.ps1') `
    -StagingEvidencePath $evidencePath `
    -ProductionContext 'production-contract' `
    -ChangeId 'CHG-TEST-001' `
    -ApprovalOwner 'Release Owner' `
    -RollbackAuthority 'Incident Commander' `
    -RollbackVersion '0.9.0' `
    -RollbackControlPlaneDigest ('sha256:' + ('3' * 64)) `
    -RollbackEdgeDigest ('sha256:' + ('4' * 64)) `
    -ObservationMinutes 15 `
    -OutputDirectory $planDirectory `
    -Force | Out-Null

$planPath = Join-Path $planDirectory 'promotion.json'
& (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$invalidApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-promotion.ps1') `
        -PlanPath $planPath `
        -StagingEvidencePath $evidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Release Owner' `
        -ApprovalStatement 'APPROVE THE WRONG CHANGE' | Out-Null
}
catch {
    $invalidApprovalRejected = $true
}
if (-not $invalidApprovalRejected) {
    throw 'The production promotion contract accepted an invalid approval statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-promotion.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Release Owner' `
    -ApprovalStatement 'APPROVE CHG-TEST-001 FOR production-contract' | Out-Null

& (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

$originalPlan = [System.IO.File]::ReadAllText($planPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['changeId'] = 'CHG-TAMPERED'
    [System.IO.File]::WriteAllText(
        $planPath,
        (($tamperedPlan | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') `
            -PlanPath $planPath `
            -StagingEvidencePath $evidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $planTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $planPath,
        $originalPlan,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $planTamperingRejected) {
    throw 'The production promotion contract accepted a tampered promotion plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($evidencePath)
$tamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($evidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') `
            -PlanPath $planPath `
            -StagingEvidencePath $evidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved | Out-Null
    }
    catch {
        $tamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText(
        $evidencePath,
        $originalEvidence,
        [System.Text.UTF8Encoding]::new($false)
    )
}
if (-not $tamperingRejected) {
    throw 'The production promotion contract accepted tampered staging evidence.'
}

& (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') `
    -PlanPath $planPath `
    -StagingEvidencePath $evidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Production promotion planning contract passed.'
