[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestAssuranceResumptionEvidence {
    param(
        [Parameter(Mandatory)][string]$PostIncidentEvidencePath,
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$ObservedTrafficPercent = 100,
        [string]$TrafficEnforcementStatus = 'confirmed',
        [string]$AssuranceScheduleStatus = 'active',
        [string]$MonitoringCoverageStatus = 'complete',
        [string]$ErrorBudgetStatus = 'within-budget',
        [string]$AlertStatus = 'clear',
        [string]$FunctionalStatus = 'passed',
        [string]$DependencyStatus = 'healthy',
        [string]$OperationalStatus = 'healthy',
        [string]$CapacityStatus = 'healthy',
        [string]$SecurityStatus = 'clear',
        [string]$ImageDriftStatus = 'clear',
        [string]$PolicyDriftStatus = 'clear',
        [string]$ConfigurationDriftStatus = 'clear',
        [string]$IdentityDriftStatus = 'clear',
        [string]$CertificateStatus = 'healthy',
        [string]$RoutingDriftStatus = 'clear',
        [string]$RollbackRetentionStatus = 'retained'
    )

    $postIncident = Get-Content -Raw -LiteralPath $PostIncidentEvidencePath | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'new-production-assurance-resumption-evidence.ps1') `
        -PostIncidentEvidencePath $PostIncidentEvidencePath `
        -ClosureEvidencePath $ClosureEvidencePath `
        -ClosurePlanPath $ClosurePlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ResumedAtUtc $ReferenceTime `
        -ObservedTrafficPercent $ObservedTrafficPercent `
        -ReviewIntervalMinutes 60 `
        -TrafficEnforcementStatus $TrafficEnforcementStatus `
        -AssuranceScheduleStatus $AssuranceScheduleStatus `
        -MonitoringCoverageStatus $MonitoringCoverageStatus `
        -ErrorBudgetStatus $ErrorBudgetStatus `
        -AlertStatus $AlertStatus `
        -FunctionalStatus $FunctionalStatus `
        -DependencyStatus $DependencyStatus `
        -OperationalStatus $OperationalStatus `
        -CapacityStatus $CapacityStatus `
        -SecurityStatus $SecurityStatus `
        -ImageDriftStatus $ImageDriftStatus `
        -PolicyDriftStatus $PolicyDriftStatus `
        -ConfigurationDriftStatus $ConfigurationDriftStatus `
        -IdentityDriftStatus $IdentityDriftStatus `
        -CertificateStatus $CertificateStatus `
        -RoutingDriftStatus $RoutingDriftStatus `
        -RollbackRetentionStatus $RollbackRetentionStatus `
        -PostIncidentGateReference ('ASSURANCE-RESUMPTION-GATE-' + [string]$postIncident.incidentId) `
        -AssuranceScheduleReference ('ASSURANCE-SCHEDULE-' + [string]$postIncident.incidentId) `
        -TrafficStateReference ('ASSURANCE-TRAFFIC-' + [string]$postIncident.incidentId) `
        -MonitoringEvidenceReference ('ASSURANCE-MONITORING-' + [string]$postIncident.incidentId) `
        -DriftEvidenceReference ('ASSURANCE-DRIFT-' + [string]$postIncident.incidentId) `
        -RollbackRetentionReference ('ASSURANCE-ROLLBACK-' + [string]$postIncident.incidentId) `
        -ReviewedBy 'Independent Assurance Resumption Reviewer' `
        -MaxPostIncidentEvidenceAgeHours 168 `
        -MaxResumptionAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'resumption-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

function Assert-Rejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$FailureMessage)

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

function Assert-ResumptionGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$PostIncidentEvidencePath,
        [Parameter(Mandatory)][string]$ClosureEvidencePath,
        [Parameter(Mandatory)][string]$ClosurePlanPath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-resumption-gate.ps1') `
            -EvidencePath $EvidencePath `
            -PostIncidentEvidencePath $PostIncidentEvidencePath `
            -ClosureEvidencePath $ClosureEvidencePath `
            -ClosurePlanPath $ClosurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$closurePlanPath = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-contract/approved/closure.json'
$closureEvidenceRoot = Join-Path $repoRoot '.shieldward/production-incident-recovery-closure-evidence-contract/passed'
$postIncidentRoot = Join-Path $repoRoot '.shieldward/production-post-incident-assurance-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-resumption-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-post-incident-assurance-contract.ps1') 6>$null

$closureEvidencePath = (Get-ChildItem -LiteralPath $closureEvidenceRoot -Filter 'closure-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$postIncidentEvidencePath = (Get-ChildItem -LiteralPath $postIncidentRoot -Filter 'assurance-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$postIncident = Get-Content -Raw -LiteralPath $postIncidentEvidencePath | ConvertFrom-Json
$resumptionClock = ([DateTimeOffset]$postIncident.collectedAtUtc).ToUniversalTime().AddMinutes(5)

$passedEvidencePath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $resumptionClock

& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-evidence.ps1') `
    -EvidencePath $passedEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $resumptionClock.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $resumptionClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [string]$passedEvidence.schedule.status -ne 'active' -or
    [string]$passedEvidence.schedule.monitoringCoverage -ne 'complete' -or
    [bool]$passedEvidence.decision.monitoringActivated -ne $true -or
    [bool]$passedEvidence.decision.assuranceResumed -ne $true -or
    [int]$passedEvidence.traffic.observedPercent -ne 100 -or
    [int]$passedEvidence.traffic.mutationPercentagePoints -ne 0 -or
    [string]$passedEvidence.rollback.retentionStatus -ne 'retained' -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy assurance resumption did not produce the required passed outcome.'
}

Assert-Rejected `
    -FailureMessage 'Assurance resumption accepted traffic outside the post-incident 100 percent boundary.' `
    -Action {
        New-TestAssuranceResumptionEvidence `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -OutputDirectory (Join-Path $testRoot 'mismatched-traffic') `
            -ObservedTrafficPercent 99 `
            -ReferenceTime $resumptionClock | Out-Null
    }

$inactiveSchedulePath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'inactive-schedule') `
    -AssuranceScheduleStatus inactive `
    -ReferenceTime $resumptionClock
$inactiveSchedule = Get-Content -Raw -LiteralPath $inactiveSchedulePath | ConvertFrom-Json
if (
    [string]$inactiveSchedule.outcome -ne 'failed' -or
    [bool]$inactiveSchedule.decision.monitoringActivated -ne $false -or
    [bool]$inactiveSchedule.decision.assuranceResumed -ne $false
) {
    throw 'An inactive assurance schedule did not block resumption.'
}
Assert-ResumptionGateRejected `
    -EvidencePath $inactiveSchedulePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ReferenceTime $resumptionClock `
    -FailureMessage 'The assurance resumption gate accepted an inactive schedule.'

$unknownMonitoringPath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'unknown-monitoring') `
    -MonitoringCoverageStatus unknown `
    -ReferenceTime $resumptionClock
$unknownMonitoring = Get-Content -Raw -LiteralPath $unknownMonitoringPath | ConvertFrom-Json
if (
    [string]$unknownMonitoring.outcome -ne 'unknown' -or
    [string]$unknownMonitoring.decision.nextAction -ne 'investigate-and-refresh-evidence'
) {
    throw 'Unknown monitoring coverage did not fail closed.'
}

$driftEvidencePath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'drift') `
    -PolicyDriftStatus detected `
    -ReferenceTime $resumptionClock
$driftEvidence = Get-Content -Raw -LiteralPath $driftEvidencePath | ConvertFrom-Json
if (
    [string]$driftEvidence.outcome -ne 'failed' -or
    [string]$driftEvidence.decision.nextAction -ne 'reaccept-before-continuing'
) {
    throw 'Material drift did not require re-acceptance.'
}

$securityIncidentPath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'security-incident') `
    -SecurityStatus incident `
    -ReferenceTime $resumptionClock
$securityIncident = Get-Content -Raw -LiteralPath $securityIncidentPath | ConvertFrom-Json
if ([string]$securityIncident.decision.nextAction -ne 'disable-and-investigate') {
    throw 'A security incident did not require disablement and investigation.'
}

$expiringCertificatePath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'expiring-certificate') `
    -CertificateStatus expiring `
    -ReferenceTime $resumptionClock
$expiringCertificate = Get-Content -Raw -LiteralPath $expiringCertificatePath | ConvertFrom-Json
if ([string]$expiringCertificate.decision.nextAction -ne 'rotate-certificates-and-refresh-evidence') {
    throw 'An expiring certificate did not require rotation and fresh evidence.'
}

$missingRollbackPath = New-TestAssuranceResumptionEvidence `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -OutputDirectory (Join-Path $testRoot 'missing-rollback') `
    -RollbackRetentionStatus missing `
    -ReferenceTime $resumptionClock
$missingRollback = Get-Content -Raw -LiteralPath $missingRollbackPath | ConvertFrom-Json
if (
    [bool]$missingRollback.decision.monitoringActivated -ne $true -or
    [bool]$missingRollback.decision.assuranceResumed -ne $false -or
    [string]$missingRollback.outcome -ne 'failed'
) {
    throw 'Missing rollback did not preserve the factual monitoring record while blocking assurance resumption.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['decision']['assuranceResumed'] = $false
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-resumption-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $resumptionClock.ToString('o') 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Assurance resumption evidence tampering was not rejected.'
}

$originalPostIncidentEvidence = [System.IO.File]::ReadAllText($postIncidentEvidencePath)
$postIncidentTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($postIncidentEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-resumption-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -PostIncidentEvidencePath $postIncidentEvidencePath `
            -ClosureEvidencePath $closureEvidencePath `
            -ClosurePlanPath $closurePlanPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $resumptionClock.ToString('o') 6>$null
    }
    catch {
        $postIncidentTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($postIncidentEvidencePath, $originalPostIncidentEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $postIncidentTamperingRejected) {
    throw 'Changed post-incident evidence was not rejected by assurance resumption validation.'
}

Assert-ResumptionGateRejected `
    -EvidencePath $passedEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ReferenceTime $resumptionClock.AddMinutes(61) `
    -FailureMessage 'The assurance resumption gate accepted stale evidence.'

& (Join-Path $PSScriptRoot 'test-production-assurance-resumption-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -PostIncidentEvidencePath $postIncidentEvidencePath `
    -ClosureEvidencePath $closureEvidencePath `
    -ClosurePlanPath $closurePlanPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $resumptionClock.ToString('o') 6>$null

Write-Host 'Continuous production assurance resumption evidence contract passed.'
