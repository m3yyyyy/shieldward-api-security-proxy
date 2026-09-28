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

function New-TestGeneration6RetentionRenewalPlan {
    param(
        [Parameter(Mandatory)][string]$TriggerEvidencePath,
        [Parameter(Mandatory)][string]$ChainHeadEvidencePath,
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][string]$RenewalEvidencePath,
        [Parameter(Mandatory)][string]$PreviousRenewalPlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][DateTimeOffset]$RequestedRetentionUntil,
        [string]$ChangeId = 'CHG-CUSTODY-RENEWAL-006'
    )

    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-6-retention-renewal-plan.ps1') `
        -TriggerEvidencePath $TriggerEvidencePath `
        -ChainHeadEvidencePath $ChainHeadEvidencePath `
        -BaselinePath $BaselinePath `
        -RenewalEvidencePath $RenewalEvidencePath `
        -PreviousRenewalPlanPath $PreviousRenewalPlanPath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId $ChangeId `
        -RequestedRetentionUntilUtc $RequestedRetentionUntil `
        -RenewalMethod 'extend-existing-object-lock' `
        -ArchiveLocationReference 'ARCHIVE-IMMUTABLE-GENERATION-006' `
        -ApprovalOwner 'Independent Generation-6 Retention Approver' `
        -CustodyOwner 'Generation-6 Evidence Custody Owner' `
        -RestoreAuthority 'Independent Generation-6 Restore Verifier' `
        -MinimumExtensionDays 365 `
        -MinimumRemainingDaysAfterNextReview 180 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 6>$null

    $safeChangeId = $ChangeId -replace '[^A-Za-z0-9._-]', '-'
    return (Join-Path $OutputDirectory "generation-6-retention-renewal-$safeChangeId.json")
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$auditRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-custody-chain-audit-contract'
$recurringRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-custody-recurring-contract'
$baselineRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-custody-baseline-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-retention-renewal-evidence-contract'
$previousPlanRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-retention-renewal-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-6-retention-renewal-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-custody-chain-audit-contract.ps1') 6>$null

$triggerEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $auditRoot 'retention-at-risk') -Filter 'generation-6-custody-chain-audit-*.json' |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
$passedAuditPath = (Get-ChildItem -LiteralPath (Join-Path $auditRoot 'passed') -Filter 'generation-6-custody-chain-audit-*.json' |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
$chainHeadPath = (Get-ChildItem -LiteralPath (Join-Path $recurringRoot 'passed-second') -Filter 'generation-6-custody-review-*.json' |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
$baselinePath = (Get-ChildItem -LiteralPath (Join-Path $baselineRoot 'passed') -Filter 'generation-6-custody-baseline-*.json' |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
$renewalEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'generation-5-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
$previousRenewalPlanPath = Join-Path $previousPlanRoot 'approved/generation-5-retention-renewal-CHG-CUSTODY-RENEWAL-005.json'
$trigger = Get-Content -Raw -LiteralPath $triggerEvidencePath | ConvertFrom-Json
$planClock = ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$trigger.retention.untilUtc).ToUniversalTime()
$requestedRetentionUntil = $currentRetentionUntil.AddDays(365)
$commonArguments = @{
    TriggerEvidencePath = $triggerEvidencePath
    ChainHeadEvidencePath = $chainHeadPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PreviousRenewalPlanPath = $previousRenewalPlanPath
    OutputDirectory = Join-Path $testRoot 'approved'
    ReferenceTime = $planClock
    RequestedRetentionUntil = $requestedRetentionUntil
}
$planPath = New-TestGeneration6RetentionRenewalPlan @commonArguments

$validationArguments = @{
    PlanPath = $planPath
    TriggerEvidencePath = $triggerEvidencePath
    ChainHeadEvidencePath = $chainHeadPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PreviousRenewalPlanPath = $previousRenewalPlanPath
    ExpectedProductionContext = 'production-contract'
    RequiredState = 'Pending'
    ReferenceTimeUtc = $planClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-plan.ps1') @validationArguments 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
if (
    [string]$pendingPlan.state -ne 'pending' -or
    [int]$pendingPlan.renewal.currentBaselineGeneration -ne 6 -or
    [int]$pendingPlan.renewal.nextBaselineGeneration -ne 7 -or
    [int]$pendingPlan.renewal.currentRenewalSequence -ne 5 -or
    [int]$pendingPlan.renewal.renewalSequence -ne 6 -or
    [bool]$pendingPlan.decision.lineagePreserved -ne $true -or
    [bool]$pendingPlan.decision.externalExecutionAuthorized -ne $false -or
    [string]$pendingPlan.decision.nextAction -ne 'obtain-independent-generation-6-retention-renewal-approval'
) {
    throw 'A valid sixth renewal request did not derive generation 7 and the pending approval boundary.'
}

$approvalArguments = @{
    PlanPath = $planPath
    TriggerEvidencePath = $triggerEvidencePath
    ChainHeadEvidencePath = $chainHeadPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PreviousRenewalPlanPath = $previousRenewalPlanPath
    ExpectedProductionContext = 'production-contract'
    ApprovedBy = 'Independent Generation-6 Retention Approver'
    ApprovedAtUtc = $planClock.AddMinutes(1).ToString('o')
}
Assert-Rejected -FailureMessage 'The generation-6 retention-renewal contract accepted an incorrect approval statement.' -Action {
    $wrongApprovalArguments = $approvalArguments.Clone()
    $wrongApprovalArguments.ApprovalStatement = 'APPROVE THE WRONG RENEWED RETENTION CHANGE'
    & (Join-Path $PSScriptRoot 'approve-production-assurance-generation-6-retention-renewal-plan.ps1') @wrongApprovalArguments 6>$null
}

$requiredStatement = 'APPROVE GENERATION 6 RETENTION RENEWAL CHG-CUSTODY-RENEWAL-006 BASELINE GENERATION 7 FOR production-contract UNTIL {0}' -f `
    $requestedRetentionUntil.ToString('yyyy-MM-dd')
$approvalArguments.ApprovalStatement = $requiredStatement
& (Join-Path $PSScriptRoot 'approve-production-assurance-generation-6-retention-renewal-plan.ps1') @approvalArguments 6>$null

$gateArguments = $validationArguments.Clone()
$gateArguments.RequiredState = 'Approved'
$gateArguments.ReferenceTimeUtc = $planClock.AddMinutes(1).ToString('o')
$gateArguments.Remove('RequiredState')
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-gate.ps1') @gateArguments 6>$null

$approvedPlan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
if (
    [string]$approvedPlan.state -ne 'approved' -or
    [string]$approvedPlan.approval.status -ne 'approved' -or
    [bool]$approvedPlan.decision.lineagePreserved -ne $true -or
    [bool]$approvedPlan.decision.externalExecutionAuthorized -ne $true -or
    [string]$approvedPlan.decision.nextAction -ne 'execute-approved-external-generation-6-retention-renewal'
) {
    throw 'The exact independent approval did not authorize only the recorded sixth renewal procedure.'
}

Assert-Rejected -FailureMessage 'A passed renewed custody chain audit was accepted as a renewal trigger.' -Action {
    $invalidArguments = $commonArguments.Clone()
    $invalidArguments.TriggerEvidencePath = $passedAuditPath
    $invalidArguments.OutputDirectory = Join-Path $testRoot 'invalid-trigger'
    New-TestGeneration6RetentionRenewalPlan @invalidArguments | Out-Null
}

Assert-Rejected -FailureMessage 'A generation-6 retention-renewal plan accepted an inadequate extension.' -Action {
    $shortArguments = $commonArguments.Clone()
    $shortArguments.OutputDirectory = Join-Path $testRoot 'short-extension'
    $shortArguments.RequestedRetentionUntil = $currentRetentionUntil.AddDays(364)
    $shortArguments.ChangeId = 'CHG-CUSTODY-RENEWAL-006-SHORT'
    New-TestGeneration6RetentionRenewalPlan @shortArguments | Out-Null
}

$wrongContextArguments = $gateArguments.Clone()
$wrongContextArguments.ExpectedProductionContext = 'wrong-production-context'
$wrongContextArguments.Remove('ReferenceTimeUtc')
Assert-Rejected -FailureMessage 'The generation-6 retention-renewal plan accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-plan.ps1') @wrongContextArguments -RequiredState Approved 6>$null
}

$originalPlan = [System.IO.File]::ReadAllText($planPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['renewal']['nextBaselineGeneration'] = 8
    [System.IO.File]::WriteAllText($planPath, (($tamperedPlan | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-plan.ps1') @gateArguments -RequiredState Approved 6>$null
    }
    catch { $planTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($planPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) { throw 'Generation-6 retention-renewal plan tampering was not rejected.' }

$originalTrigger = [System.IO.File]::ReadAllText($triggerEvidencePath)
$triggerTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($triggerEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-plan.ps1') @gateArguments -RequiredState Approved 6>$null
    }
    catch { $triggerTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($triggerEvidencePath, $originalTrigger, [System.Text.UTF8Encoding]::new($false))
}
if (-not $triggerTamperingRejected) { throw 'Changed generation-6 custody chain-audit trigger was not rejected.' }

$staleGateArguments = $gateArguments.Clone()
$staleGateArguments.MaxPlanAgeMinutes = 60
$staleGateArguments.ReferenceTimeUtc = $planClock.AddMinutes(62).ToString('o')
Assert-Rejected -FailureMessage 'The generation-6 retention-renewal gate accepted stale approval.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-gate.ps1') @staleGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-6-retention-renewal-gate.ps1') @gateArguments 6>$null

Write-Host 'Generation-6 production assurance retention-renewal planning contract passed.'
