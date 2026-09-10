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

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-TestResponsePlan {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$IncidentId,
        [Parameter(Mandatory)][string]$ChangeId,
        [Parameter(Mandatory)][string]$ResponseAction
    )

    $evidence = Get-Content -Raw -LiteralPath $EvidencePath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-incident-response-plan.ps1') `
        -AssuranceEvidencePath $EvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -IncidentId $IncidentId `
        -ChangeId $ChangeId `
        -ResponseOwner ([string]$evidence.rollback.authority) `
        -ResponseAction $ResponseAction `
        -ResponseDeadlineMinutes 30 `
        -MaxEvidenceAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -Force 6>$null

    return (Join-Path $OutputDirectory 'response.json')
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$assuranceContractRoot = Join-Path $repoRoot '.shieldward/production-assurance-contract'
$passedEvidencePath = Join-Path $assuranceContractRoot 'assurance-evidence.json'
$unknownEvidencePath = Join-Path $assuranceContractRoot 'unknown-evidence.json'
$driftEvidencePath = Join-Path $assuranceContractRoot 'drift-evidence.json'
$failedEvidencePath = Join-Path $assuranceContractRoot 'failed-evidence.json'
$certificateEvidencePath = Join-Path $assuranceContractRoot 'certificate-evidence.json'
$testRoot = Join-Path $repoRoot '.shieldward/production-incident-response-contract'
$staleEvidencePath = Join-Path $testRoot 'stale-drift-evidence.json'

& (Join-Path $PSScriptRoot 'test-production-assurance-contract.ps1') 6>$null
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$driftPlanPath = New-TestResponsePlan `
    -EvidencePath $driftEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'drift') `
    -IncidentId 'INC-TEST-001' `
    -ChangeId 'CHG-TEST-001' `
    -ResponseAction 'reaccept-before-continuing'
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $driftPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null
$driftPlan = Get-Content -Raw -LiteralPath $driftPlanPath | ConvertFrom-Json
if (
    [bool]$driftPlan.decision.reacceptanceRequired -ne $true -or
    [string]$driftPlan.response.action -ne 'reaccept-before-continuing' -or
    [int]$driftPlan.traffic.targetPercent -ne 100
) {
    throw 'Material drift did not produce the required freeze-and-reaccept response boundary.'
}

$passedEvidenceRejected = $false
try {
    New-TestResponsePlan `
        -EvidencePath $passedEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'passed') `
        -IncidentId 'INC-TEST-002' `
        -ChangeId 'CHG-TEST-002' `
        -ResponseAction 'investigate-and-refresh-evidence' | Out-Null
}
catch {
    $passedEvidenceRejected = $true
}
if (-not $passedEvidenceRejected) {
    throw 'Incident response planning accepted a passed assurance snapshot.'
}

$actionMismatchRejected = $false
try {
    New-TestResponsePlan `
        -EvidencePath $driftEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'action-mismatch') `
        -IncidentId 'INC-TEST-003' `
        -ChangeId 'CHG-TEST-003' `
        -ResponseAction 'disable-and-investigate' | Out-Null
}
catch {
    $actionMismatchRejected = $true
}
if (-not $actionMismatchRejected) {
    throw 'Incident response planning allowed an action inconsistent with assurance evidence.'
}

$healthPlanPath = New-TestResponsePlan `
    -EvidencePath $failedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'health') `
    -IncidentId 'INC-TEST-004' `
    -ChangeId 'CHG-TEST-004' `
    -ResponseAction 'rollback-to-75-and-investigate'
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $healthPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null
$healthPlan = Get-Content -Raw -LiteralPath $healthPlanPath | ConvertFrom-Json
if ([int]$healthPlan.traffic.targetPercent -ne 75) {
    throw 'The bounded rollback response did not target the recorded 75 percent cohort.'
}

$disablePlanPath = New-TestResponsePlan `
    -EvidencePath $failedEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'disable') `
    -IncidentId 'INC-TEST-005' `
    -ChangeId 'CHG-TEST-005' `
    -ResponseAction 'disable-and-investigate'
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $disablePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null
$disablePlan = Get-Content -Raw -LiteralPath $disablePlanPath | ConvertFrom-Json
if ([int]$disablePlan.traffic.targetPercent -ne 0) {
    throw 'The disable response did not target externally enforced zero traffic.'
}

$certificatePlanPath = New-TestResponsePlan `
    -EvidencePath $certificateEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'certificate') `
    -IncidentId 'INC-TEST-006' `
    -ChangeId 'CHG-TEST-006' `
    -ResponseAction 'rotate-certificates-and-refresh-evidence'
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $certificatePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$unknownPlanPath = New-TestResponsePlan `
    -EvidencePath $unknownEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -IncidentId 'INC-TEST-007' `
    -ChangeId 'CHG-TEST-007' `
    -ResponseAction 'investigate-and-refresh-evidence'
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $unknownPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending | Out-Null

$staleEvidence = Get-Content -Raw -LiteralPath $driftEvidencePath | ConvertFrom-Json -AsHashtable
$staleCollectedAt = [DateTimeOffset]::UtcNow.AddMinutes(-120)
$staleEvidence['collectedAtUtc'] = $staleCollectedAt.ToString('o')
$staleEvidence['schedule']['nextReviewDueAtUtc'] = $staleCollectedAt.AddMinutes(60).ToString('o')
Set-AssuranceEvidenceIntegrity -Evidence $staleEvidence
Write-JsonFile -Path $staleEvidencePath -Value $staleEvidence
$staleEvidenceRejected = $false
try {
    New-TestResponsePlan `
        -EvidencePath $staleEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'stale') `
        -IncidentId 'INC-TEST-008' `
        -ChangeId 'CHG-TEST-008' `
        -ResponseAction 'reaccept-before-continuing' | Out-Null
}
catch {
    $staleEvidenceRejected = $true
}
if (-not $staleEvidenceRejected) {
    throw 'Incident response planning accepted stale assurance evidence.'
}

$originalPlan = [System.IO.File]::ReadAllText($driftPlanPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['traffic']['targetPercent'] = 0
    Write-JsonFile -Path $driftPlanPath -Value $tamperedPlan
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
            -PlanPath $driftPlanPath `
            -ExpectedProductionContext 'production-contract' | Out-Null
    }
    catch {
        $planTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($driftPlanPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) {
    throw 'The incident response validator allowed a tampered response plan.'
}

$originalEvidence = [System.IO.File]::ReadAllText($driftEvidencePath)
$evidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($driftEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
            -PlanPath $driftPlanPath `
            -ExpectedProductionContext 'production-contract' | Out-Null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($driftEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'The incident response validator allowed changed assurance evidence.'
}

$driftPlan = Get-Content -Raw -LiteralPath $driftPlanPath | ConvertFrom-Json
$incorrectApprovalRejected = $false
try {
    & (Join-Path $PSScriptRoot 'approve-production-incident-response-plan.ps1') `
        -PlanPath $driftPlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy ([string]$driftPlan.approval.owner) `
        -ApprovalStatement 'APPROVE SOMETHING ELSE' | Out-Null
}
catch {
    $incorrectApprovalRejected = $true
}
if (-not $incorrectApprovalRejected) {
    throw 'The incident response approval accepted an incorrect statement.'
}

& (Join-Path $PSScriptRoot 'approve-production-incident-response-plan.ps1') `
    -PlanPath $driftPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy ([string]$driftPlan.approval.owner) `
    -ApprovalStatement ([string]$driftPlan.approval.requiredStatement) | Out-Null
& (Join-Path $PSScriptRoot 'test-production-incident-response-plan.ps1') `
    -PlanPath $driftPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Approved | Out-Null

Write-Host 'Production incident response planning contract passed.'
