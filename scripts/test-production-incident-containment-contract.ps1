[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Approve-TestPlan {
    param([Parameter(Mandatory)][string]$PlanPath)

    $plan = Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json
    if ([string]$plan.state -eq 'pending') {
        & (Join-Path $PSScriptRoot 'approve-production-incident-response-plan.ps1') `
            -PlanPath $PlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ApprovedBy ([string]$plan.approval.owner) `
            -ApprovalStatement ([string]$plan.approval.requiredStatement) 6>$null
    }
}

function New-TestContainmentEvidence {
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][int]$ObservedTrafficPercent,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$WorkloadVerificationStatus = 'confirmed',
        [string]$ResponseExecutionStatus = 'completed',
        [string]$IncidentRecordStatus = 'updated'
    )

    $plan = Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-incident-containment-evidence.ps1') `
        -PlanPath $PlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutedAtUtc ([DateTimeOffset]::UtcNow) `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -WorkloadVerificationStatus $WorkloadVerificationStatus `
        -ResponseExecutionStatus $ResponseExecutionStatus `
        -IncidentRecordStatus $IncidentRecordStatus `
        -TrafficStateReference ("TRAFFIC-" + [string]$plan.incidentId) `
        -WorkloadEvidenceReference ("WORKLOAD-" + [string]$plan.incidentId) `
        -ResponseExecutionReference ("EXECUTION-" + [string]$plan.incidentId) `
        -IncidentRecordReference ("INCIDENT-" + [string]$plan.incidentId) `
        -CollectedBy 'Containment Reviewer' `
        -MaxExecutionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'containment-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-GateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw $FailureMessage
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$responseRoot = Join-Path $repoRoot '.shieldward/production-incident-response-contract'
$driftPlanPath = Join-Path $responseRoot 'drift/response.json'
$healthPlanPath = Join-Path $responseRoot 'health/response.json'
$disablePlanPath = Join-Path $responseRoot 'disable/response.json'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-containment-contract'

& (Join-Path $PSScriptRoot 'test-production-incident-response-contract.ps1') 6>$null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$pendingPlanRejected = $false
try {
    New-TestContainmentEvidence `
        -PlanPath $healthPlanPath `
        -OutputDirectory (Join-Path $testRoot 'pending') `
        -ObservedTrafficPercent 75 | Out-Null
}
catch {
    $pendingPlanRejected = $true
}
if (-not $pendingPlanRejected) {
    throw 'Containment evidence accepted a response plan without explicit approval.'
}

Approve-TestPlan -PlanPath $healthPlanPath
Approve-TestPlan -PlanPath $disablePlanPath

$holdEvidencePath = New-TestContainmentEvidence `
    -PlanPath $driftPlanPath `
    -OutputDirectory (Join-Path $testRoot 'hold') `
    -ObservedTrafficPercent 100
& (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
    -EvidencePath $holdEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$holdEvidence = Get-Content -Raw -LiteralPath $holdEvidencePath | ConvertFrom-Json
if (
    [int]$holdEvidence.traffic.observedPercent -ne 100 -or
    [string]$holdEvidence.decision.nextAction -ne 'perform-reacceptance-before-restoration'
) {
    throw 'The hold-at-100 response boundary did not preserve mandatory re-acceptance.'
}

$rollbackEvidencePath = New-TestContainmentEvidence `
    -PlanPath $healthPlanPath `
    -OutputDirectory (Join-Path $testRoot 'rollback') `
    -ObservedTrafficPercent 75
& (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
    -EvidencePath $rollbackEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$rollbackEvidence = Get-Content -Raw -LiteralPath $rollbackEvidencePath | ConvertFrom-Json
if (
    [int]$rollbackEvidence.traffic.observedPercent -ne 75 -or
    [string]$rollbackEvidence.decision.nextAction -ne 'remediate-and-prepare-recovery'
) {
    throw 'The rollback response boundary did not preserve the recorded 75 percent cohort.'
}

$disableEvidencePath = New-TestContainmentEvidence `
    -PlanPath $disablePlanPath `
    -OutputDirectory (Join-Path $testRoot 'disable') `
    -ObservedTrafficPercent 0
& (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
    -EvidencePath $disableEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
$disableEvidence = Get-Content -Raw -LiteralPath $disableEvidencePath | ConvertFrom-Json
if (
    [int]$disableEvidence.traffic.observedPercent -ne 0 -or
    [string]$disableEvidence.decision.nextAction -ne 'remediate-before-restoration'
) {
    throw 'The disable response boundary did not prove externally enforced zero traffic.'
}

$mismatchedTrafficPath = New-TestContainmentEvidence `
    -PlanPath $disablePlanPath `
    -OutputDirectory (Join-Path $testRoot 'traffic-mismatch') `
    -ObservedTrafficPercent 1
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') `
    -EvidencePath $mismatchedTrafficPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Assert-GateRejected `
    -EvidencePath $mismatchedTrafficPath `
    -FailureMessage 'The containment gate allowed traffic outside the approved response boundary.'

$failedVerificationPath = New-TestContainmentEvidence `
    -PlanPath $disablePlanPath `
    -OutputDirectory (Join-Path $testRoot 'failed-verification') `
    -ObservedTrafficPercent 0 `
    -WorkloadVerificationStatus failed
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') `
    -EvidencePath $failedVerificationPath `
    -ExpectedProductionContext 'production-contract' 6>$null
Assert-GateRejected `
    -EvidencePath $failedVerificationPath `
    -FailureMessage 'The containment gate allowed failed workload verification.'

$unknownVerificationPath = New-TestContainmentEvidence `
    -PlanPath $disablePlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-verification') `
    -ObservedTrafficPercent 0 `
    -TrafficEnforcementStatus unknown
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') `
    -EvidencePath $unknownVerificationPath `
    -ExpectedProductionContext 'production-contract' 6>$null
$unknownVerificationEvidence = Get-Content -Raw -LiteralPath $unknownVerificationPath | ConvertFrom-Json
if ([bool]$unknownVerificationEvidence.traffic.externallyEnforced) {
    throw 'Unknown traffic enforcement was incorrectly recorded as externally enforced.'
}
Assert-GateRejected `
    -EvidencePath $unknownVerificationPath `
    -FailureMessage 'The containment gate allowed unknown traffic enforcement.'

$originalEvidence = [System.IO.File]::ReadAllText($disableEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['externalEvidence']['trafficStateReference'] = 'TAMPERED-TRAFFIC-REFERENCE'
    [System.IO.File]::WriteAllText(
        $disableEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
            -EvidencePath $disableEvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($disableEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The containment gate allowed tampered execution evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($disablePlanPath)
$approvedPlanTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($disablePlanPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
            -EvidencePath $disableEvidencePath `
            -ExpectedProductionContext 'production-contract' 6>$null
    }
    catch {
        $approvedPlanTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($disablePlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $approvedPlanTamperingRejected) {
    throw 'The containment gate allowed a changed approved response plan.'
}

& (Join-Path $PSScriptRoot 'test-production-incident-containment-gate.ps1') `
    -EvidencePath $disableEvidencePath `
    -ExpectedProductionContext 'production-contract' 6>$null
Write-Host 'Production incident containment evidence contract passed.'
