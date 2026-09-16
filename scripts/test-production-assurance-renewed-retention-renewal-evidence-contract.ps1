[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Rejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$FailureMessage)

    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw $FailureMessage }
}

function New-TestRenewedRetentionRenewalEvidence {
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][DateTimeOffset]$ObservedRetentionUntil,
        [string]$ExternalChangeStatus = 'completed',
        [string]$RetentionPolicyStatus = 'active',
        [string]$ObjectLockStatus = 'enforced',
        [string]$ArchiveInventoryStatus = 'complete',
        [string]$EncryptionStatus = 'verified',
        [string]$AccessControlStatus = 'least-privilege',
        [string]$RestoreVerificationStatus = 'passed'
    )

    & (Join-Path $PSScriptRoot 'new-production-assurance-renewed-retention-renewal-evidence.ps1') `
        -PlanPath $PlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ExecutionCompletedAtUtc $ReferenceTime `
        -ObservedRetentionUntilUtc $ObservedRetentionUntil `
        -ExternalChangeStatus $ExternalChangeStatus `
        -RetentionPolicyStatus $RetentionPolicyStatus `
        -ObjectLockStatus $ObjectLockStatus `
        -ArchiveInventoryStatus $ArchiveInventoryStatus `
        -EncryptionStatus $EncryptionStatus `
        -AccessControlStatus $AccessControlStatus `
        -RestoreVerificationStatus $RestoreVerificationStatus `
        -ExternalChangeReference 'RENEWED-RETENTION-CHANGE-RESULT-002' `
        -RetentionPolicyReference 'RENEWED-RETENTION-POLICY-RESULT-002' `
        -ObjectLockReference 'RENEWED-OBJECT-LOCK-RESULT-002' `
        -ArchiveInventoryReference 'RENEWED-ARCHIVE-INVENTORY-RESULT-002' `
        -EncryptionReference 'RENEWED-ENCRYPTION-RESULT-002' `
        -AccessReviewReference 'RENEWED-ACCESS-REVIEW-RESULT-002' `
        -RestoreTestReference 'RENEWED-RESTORE-TEST-RESULT-002' `
        -ExecutedBy 'External Renewed Archive Custody Operator' `
        -VerifiedBy 'Independent Renewed Retention Verifier' `
        -MaxApprovedPlanAgeMinutes 60 `
        -MaxExecutionEvidenceAgeMinutes 60 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'renewed-retention-renewal-evidence-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-evidence-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/renewed-retention-renewal-CHG-CUSTODY-RENEWAL-002.json'
$plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
$executionClock = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime().AddMinutes(1)
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$plan.renewal.currentRetentionUntilUtc).ToUniversalTime()

$passedEvidencePath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'passed') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil

& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence.ps1') `
    -EvidencePath $passedEvidencePath `
    -PlanPath $planPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $executionClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -PlanPath $planPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $executionClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.renewal.nextBaselineGeneration -ne 3 -or
    [int]$passedEvidence.renewal.renewalSequence -ne 2 -or
    [bool]$passedEvidence.renewal.retentionExtended -ne $true -or
    [bool]$passedEvidence.renewal.observedMeetsApprovedBoundary -ne $true -or
    [bool]$passedEvidence.renewal.observedCoversNextReview -ne $true -or
    [bool]$passedEvidence.decision.lineagePreserved -ne $true -or
    [bool]$passedEvidence.decision.retentionRenewalProven -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'establish-next-renewed-custody-review-baseline'
) {
    throw 'A successful second external retention renewal did not produce passed evidence for generation three.'
}

$failedChangePath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'failed-change') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $currentRetentionUntil `
    -ExternalChangeStatus failed
$failedChange = Get-Content -Raw -LiteralPath $failedChangePath | ConvertFrom-Json
if ([string]$failedChange.outcome -ne 'failed' -or [string]$failedChange.decision.nextAction -ne 'retry-or-escalate-renewed-retention-renewal') {
    throw 'A failed second external retention change did not require retry or escalation.'
}

$insufficientRetentionPath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'insufficient-retention') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $currentRetentionUntil.AddDays(30)
$insufficientRetention = Get-Content -Raw -LiteralPath $insufficientRetentionPath | ConvertFrom-Json
if (
    [bool]$insufficientRetention.renewal.observedMeetsApprovedBoundary -ne $false -or
    [string]$insufficientRetention.decision.nextAction -ne 'quarantine-and-repair-renewed-retention'
) {
    throw 'An insufficient renewed retention boundary did not require quarantine and repair.'
}

$inactiveRetentionPath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'inactive-retention') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil `
    -RetentionPolicyStatus inactive
$inactiveRetention = Get-Content -Raw -LiteralPath $inactiveRetentionPath | ConvertFrom-Json
if ([string]$inactiveRetention.decision.nextAction -ne 'quarantine-and-repair-renewed-retention') {
    throw 'Inactive renewed retention did not require quarantine and repair.'
}

$incompleteInventoryPath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'incomplete-inventory') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil `
    -ArchiveInventoryStatus incomplete
$incompleteInventory = Get-Content -Raw -LiteralPath $incompleteInventoryPath | ConvertFrom-Json
if ([string]$incompleteInventory.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Incomplete renewed archive inventory did not require restoration and investigation.'
}

$overbroadAccessPath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'overbroad-access') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil `
    -AccessControlStatus overbroad
$overbroadAccess = Get-Content -Raw -LiteralPath $overbroadAccessPath | ConvertFrom-Json
if ([string]$overbroadAccess.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Overbroad renewed archive access did not require restriction and investigation.'
}

$failedRestorePath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'failed-restore') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil `
    -RestoreVerificationStatus failed
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed renewed restore verification did not require archive repair and retesting.'
}

$unknownEvidencePath = New-TestRenewedRetentionRenewalEvidence `
    -PlanPath $planPath `
    -OutputDirectory (Join-Path $testRoot 'unknown') `
    -ReferenceTime $executionClock `
    -ObservedRetentionUntil $requestedRetentionUntil `
    -ObjectLockStatus unknown
$unknownEvidence = Get-Content -Raw -LiteralPath $unknownEvidencePath | ConvertFrom-Json
if ([string]$unknownEvidence.outcome -ne 'unknown' -or [string]$unknownEvidence.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown second-renewal control evidence did not fail closed.'
}

Assert-Rejected -FailureMessage 'The renewed retention-renewal evidence gate accepted a failed external change.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence-gate.ps1') `
        -EvidencePath $failedChangePath `
        -PlanPath $planPath `
        -ExpectedProductionContext 'production-contract' `
        -ReferenceTimeUtc $executionClock.ToString('o') 6>$null
}

$wrongContextArguments = @{
    EvidencePath = $passedEvidencePath
    PlanPath = $planPath
    ExpectedProductionContext = 'wrong-production-context'
}
Assert-Rejected -FailureMessage 'Renewed retention-renewal evidence accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence.ps1') @wrongContextArguments 6>$null
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['renewal']['renewalSequence'] = 3
    [System.IO.File]::WriteAllText($passedEvidencePath, (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -PlanPath $planPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $executionClock.ToString('o') 6>$null
    }
    catch { $evidenceTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) { throw 'Renewed retention-renewal evidence tampering was not rejected.' }

$originalPlan = [System.IO.File]::ReadAllText($planPath)
$planTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($planPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence.ps1') `
            -EvidencePath $passedEvidencePath `
            -PlanPath $planPath `
            -ExpectedProductionContext 'production-contract' `
            -ReferenceTimeUtc $executionClock.ToString('o') 6>$null
    }
    catch { $planTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($planPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) { throw 'Changed approved renewed retention-renewal plan was not rejected.' }

Assert-Rejected -FailureMessage 'The renewed retention-renewal evidence gate accepted stale evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence-gate.ps1') `
        -EvidencePath $passedEvidencePath `
        -PlanPath $planPath `
        -ExpectedProductionContext 'production-contract' `
        -MaxEvidenceAgeMinutes 60 `
        -ReferenceTimeUtc $executionClock.AddMinutes(61).ToString('o') 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-evidence-gate.ps1') `
    -EvidencePath $passedEvidencePath `
    -PlanPath $planPath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $executionClock.ToString('o') 6>$null

Write-Host 'Renewed production assurance retention-renewal execution evidence contract passed.'
