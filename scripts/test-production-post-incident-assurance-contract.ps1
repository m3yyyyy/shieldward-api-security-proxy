[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestPostIncidentAssuranceEvidence {
    param(
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = 100,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$CurrentIncidentStatus = 'closed',
        [string]$SustainedHealthStatus = 'healthy',
        [string]$ErrorBudgetStatus = 'within-budget',
        [string]$SecurityReviewStatus = 'complete',
        [string]$RootCauseAnalysisStatus = 'complete',
        [string]$CorrectiveActionsStatus = 'tracked',
        [string]$RetrospectiveStatus = 'completed',
        [string]$RollbackRetentionStatus = 'retained',
        [string]$AuditEvidenceStatus = 'complete'
    )

    $closure = Get-Content -Raw -LiteralPath $ClosureEvidencePath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-post-incident-assurance-evidence.ps1') `
        -ClosureEvidencePath $ClosureEvidencePath `
        -ClosurePlanPath $ClosurePlanPath `
        -ExpectedProductionContext 'production-contract' `
        -AssessedAtUtc $ReferenceTime `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -CurrentIncidentStatus $CurrentIncidentStatus `
        -SustainedHealthStatus $SustainedHealthStatus `
        -ErrorBudgetStatus $ErrorBudgetStatus `
        -SecurityReviewStatus $SecurityReviewStatus `
        -RootCauseAnalysisStatus $RootCauseAnalysisStatus `
        -CorrectiveActionsStatus $CorrectiveActionsStatus `
        -RetrospectiveStatus $RetrospectiveStatus `
        -RollbackRetentionStatus $RollbackRetentionStatus `
        -AuditEvidenceStatus $AuditEvidenceStatus `
        -ClosureEvidenceGateReference ('POST-INCIDENT-CLOSURE-GATE-' + [string]$closure.closureChangeId) `
        -IncidentRecordReference ('POST-INCIDENT-RECORD-' + [string]$closure.incidentId) `
        -AssuranceWindowReference ('POST-INCIDENT-ASSURANCE-' + [string]$closure.incidentId) `
        -ErrorBudgetReference ('POST-INCIDENT-BUDGET-' + [string]$closure.incidentId) `
        -SecurityReviewReference ('POST-INCIDENT-SECURITY-' + [string]$closure.incidentId) `
        -RootCauseAnalysisReference ('POST-INCIDENT-RCA-' + [string]$closure.incidentId) `
        -CorrectiveActionsReference ('POST-INCIDENT-ACTIONS-' + [string]$closure.incidentId) `
        -RetrospectiveReference ('POST-INCIDENT-RETRO-' + [string]$closure.incidentId) `
        -TrafficStateReference ('POST-INCIDENT-TRAFFIC-' + [string]$closure.incidentId) `
        -RollbackRetentionReference ('POST-INCIDENT-ROLLBACK-' + [string]$closure.incidentId) `
        -AuditEvidenceReference ('POST-INCIDENT-AUDIT-' + [string]$closure.incidentId) `
        -CollectedBy 'Independent Post-Incident Assurance Collector' `
        -MinimumAssuranceWindowHours 24 `
        -MaxClosureEvidenceAgeHours 720 `
        -MaxAssessmentAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'assurance-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $rejected = $false
    try {
        & $Action
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw $FailureMessage
    }
}

function Assert-AssuranceGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-gate.ps1') `
            -EvidencePath $EvidencePath `
            -ClosureEvidencePath $ClosureEvidencePath `
            -ClosurePlanPath $ClosurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$closurePlanRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-contract'
$closureEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-post-incident-assurance-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-incident-recovery-closure-evidence-contract.ps1') 6>$null

$approvedPlanPath = Join-Path $closurePlanRoot 'approved/closure.json'
$passedClosureEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $closureEvidenceRoot 'passed') -Filter 'closure-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$closureEvidence = Get-Content -Raw -LiteralPath $passedClosureEvidencePath | ConvertFrom-Json
$assuranceClock = ([DateTimeOffset]$closureEvidence.execution.closedAtUtc).ToUniversalTime().AddHours(24)

$passedEvidencePath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $assuranceClock

& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-evidence.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $assuranceClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $assuranceClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [string]$passedEvidence.incident.status -ne 'closed' -or
    [string]$passedEvidence.assurance.sustainedHealth -ne 'healthy' -or
    [string]$passedEvidence.assurance.errorBudget -ne 'within-budget' -or
    [bool]$passedEvidence.retrospective.recorded -ne $true -or
    [int]$passedEvidence.traffic.observedPercent -ne 100 -or
    [int]$passedEvidence.traffic.mutationPercentagePoints -ne 0 -or
    [string]$passedEvidence.rollback.retentionStatus -ne 'retained' -or
    [string]$passedEvidence.decision.nextAction -ne 'resume-continuous-production-assurance'
) {
    throw 'Healthy post-incident assurance did not produce the required passed outcome.'
}

Assert-Rejected `
    -FailureMessage 'Post-incident assurance accepted traffic outside the closed 100 percent boundary.' `
    -Action {
        New-TestPostIncidentAssuranceEvidence `
            -ClosureEvidencePath $passedClosureEvidencePath `
            -ClosurePlanPath $approvedPlanPath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-traffic') `
            -ObservedTrafficPercent 99 `
            -ReferenceTime $assuranceClock | Out-Null
    }

$reopenedIncidentPath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'reopened-incident') `
    -CurrentIncidentStatus reopened `
    -ReferenceTime $assuranceClock
$reopenedIncident = Get-Content -Raw -LiteralPath $reopenedIncidentPath | ConvertFrom-Json
if ([string]$reopenedIncident.outcome -ne 'failed') {
    throw 'A reopened incident did not produce a failed assurance outcome.'
}
Assert-AssuranceGateRejected `
    -EvidencePath $reopenedIncidentPath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $assuranceClock `
    -FailureMessage 'The post-incident assurance gate accepted a reopened incident.'

$degradedHealthPath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'degraded-health') `
    -SustainedHealthStatus degraded `
    -ReferenceTime $assuranceClock
Assert-AssuranceGateRejected `
    -EvidencePath $degradedHealthPath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $assuranceClock `
    -FailureMessage 'The post-incident assurance gate accepted degraded sustained health.'

$unknownSecurityPath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-security') `
    -SecurityReviewStatus unknown `
    -ReferenceTime $assuranceClock
$unknownSecurity = Get-Content -Raw -LiteralPath $unknownSecurityPath | ConvertFrom-Json
if (
    [string]$unknownSecurity.outcome -ne 'unknown' -or
    [string]$unknownSecurity.decision.nextAction -ne 'treat-assurance-as-incomplete-and-collect-evidence'
) {
    throw 'Unknown post-incident security evidence did not fail closed.'
}

$incompleteRetrospectivePath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'incomplete-retrospective') `
    -RootCauseAnalysisStatus incomplete `
    -RetrospectiveStatus incomplete `
    -ReferenceTime $assuranceClock
$incompleteRetrospective = Get-Content -Raw -LiteralPath $incompleteRetrospectivePath | ConvertFrom-Json
if (
    [string]$incompleteRetrospective.outcome -ne 'failed' -or
    [bool]$incompleteRetrospective.retrospective.recorded -ne $false
) {
    throw 'Incomplete retrospective evidence did not produce a failed unrecorded outcome.'
}

$missingRollbackPath = New-TestPostIncidentAssuranceEvidence `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -OutputDirectory (Join-Path $testRoot 'missing-rollback') `
    -RollbackRetentionStatus missing `
    -ReferenceTime $assuranceClock
$missingRollback = Get-Content -Raw -LiteralPath $missingRollbackPath | ConvertFrom-Json
if (
    [bool]$missingRollback.retrospective.recorded -ne $true -or
    [string]$missingRollback.outcome -ne 'failed' -or
    [string]$missingRollback.decision.nextAction -ne 'reopen-or-escalate-incident-and-preserve-rollback'
) {
    throw 'Missing rollback did not preserve the factual retrospective record while failing assurance.'
}
Assert-AssuranceGateRejected `
    -EvidencePath $missingRollbackPath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $assuranceClock `
    -FailureMessage 'The post-incident assurance gate accepted missing rollback evidence.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['retrospective']['recorded'] = $false
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ClosureEvidencePath $passedClosureEvidencePath `
            -ClosurePlanPath $approvedPlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $assuranceClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Post-incident assurance evidence tampering was not rejected.'
}

$originalClosureEvidence = [System.IO.File]::ReadAllText($passedClosureEvidencePath)
$closureEvidenceTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedClosureEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -ClosureEvidencePath $passedClosureEvidencePath `
            -ClosurePlanPath $approvedPlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $assuranceClock.ToString('o') 6>$null
    }
    catch {
        $closureEvidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedClosureEvidencePath, $originalClosureEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $closureEvidenceTamperingRejected) {
    throw 'Changed incident-closure evidence was not rejected by post-incident assurance validation.'
}

Assert-AssuranceGateRejected `
    -EvidencePath $passedEvidencePath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ReferenceTime $assuranceClock.AddMinutes(61) `
    -FailureMessage 'The post-incident assurance gate accepted stale evidence.'

& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -ClosureEvidencePath $passedClosureEvidencePath `
    -ClosurePlanPath $approvedPlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $assuranceClock.ToString('o') 6>$null

Write-Host 'Production post-incident assurance and retrospective evidence contract passed.'
