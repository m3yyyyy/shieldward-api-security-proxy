[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function New-TestRetentionRenewalPlan {
    param(
        [Parameter(Mandatory)][string]$TriggerEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][DateTimeOffset]$RequestedRetentionUntil,
        [string]$ChangeId = 'CHG-CUSTODY-RENEWAL-001'
    )

    & (Join-Path $PSScriptRoot 'new-production-assurance-retention-renewal-plan.ps1') `
        -TriggerEvidencePath $TriggerEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ChangeId $ChangeId `
        -RequestedRetentionUntilUtc $RequestedRetentionUntil `
        -RenewalMethod 'extend-existing-object-lock' `
        -ArchiveLocationReference 'ARCHIVE-IMMUTABLE-GENERATION-001' `
        -ApprovalOwner 'Independent Retention Approver' `
        -CustodyOwner 'Evidence Custody Owner' `
        -RestoreAuthority 'Independent Restore Verifier' `
        -MinimumExtensionDays 365 `
        -MinimumRemainingDaysAfterNextReview 180 `
        -OutputDirectory $OutputDirectory `
        -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') `
        -Force 6>$null

    $safeChangeId = $ChangeId -replace '[^A-Za-z0-9._-]', '-'
    return (Join-Path $OutputDirectory "retention-renewal-$safeChangeId.json")
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$custodyAuditRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-chain-audit-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-retention-renewal-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-custody-chain-audit-contract.ps1') 6>$null

$triggerEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $custodyAuditRoot 'missing-retention') -Filter 'custody-chain-audit-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$passedAuditPath = (Get-ChildItem -LiteralPath (Join-Path $custodyAuditRoot 'passed-sequence-3') -Filter 'custody-chain-audit-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$trigger = Get-Content -Raw -LiteralPath $triggerEvidencePath | ConvertFrom-Json
$planClock = ([DateTimeOffset]$trigger.collectedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$trigger.rootCustodyEvidence.retentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil = $currentRetentionUntil.AddDays(365)
$planPath = New-TestRetentionRenewalPlan `
    -TriggerEvidencePath $triggerEvidencePath `
    -OutputDirectory (Join-Path $testRoot 'approved') `
    -ReferenceTime $planClock `
    -RequestedRetentionUntil $requestedRetentionUntil

& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-plan.ps1') `
    -PlanPath $planPath `
    -TriggerEvidencePath $triggerEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -RequiredState Pending `
    -ReferenceTimeUtc $planClock.ToString('o') 6>$null

$pendingPlan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
if (
    [string]$pendingPlan.state -ne 'pending' -or
    [bool]$pendingPlan.renewal.sufficientForNextReview -ne $true -or
    [bool]$pendingPlan.decision.externalExecutionAuthorized -ne $false -or
    [string]$pendingPlan.decision.nextAction -ne 'obtain-independent-retention-renewal-approval'
) {
    throw 'A valid retention-renewal request did not create a pending approval boundary.'
}

Assert-Rejected -FailureMessage 'The retention-renewal contract accepted an incorrect approval statement.' -Action {
    & (Join-Path $PSScriptRoot 'approve-production-assurance-retention-renewal-plan.ps1') `
        -PlanPath $planPath `
        -TriggerEvidencePath $triggerEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -ApprovedBy 'Independent Retention Approver' `
        -ApprovalStatement 'APPROVE THE WRONG RETENTION CHANGE' `
        -ApprovedAtUtc $planClock.AddMinutes(1).ToString('o') 6>$null
}

$requiredStatement = 'APPROVE RETENTION RENEWAL CHG-CUSTODY-RENEWAL-001 FOR production-contract UNTIL {0}' -f `
    $requestedRetentionUntil.ToString('yyyy-MM-dd')
$approvedAt = $planClock.AddMinutes(1)
& (Join-Path $PSScriptRoot 'approve-production-assurance-retention-renewal-plan.ps1') `
    -PlanPath $planPath `
    -TriggerEvidencePath $triggerEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ApprovedBy 'Independent Retention Approver' `
    -ApprovalStatement $requiredStatement `
    -ApprovedAtUtc $approvedAt.ToString('o') 6>$null

& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-gate.ps1') `
    -PlanPath $planPath `
    -TriggerEvidencePath $triggerEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $approvedAt.ToString('o') 6>$null

$approvedPlan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
if (
    [string]$approvedPlan.state -ne 'approved' -or
    [string]$approvedPlan.approval.status -ne 'approved' -or
    [bool]$approvedPlan.decision.externalExecutionAuthorized -ne $true -or
    [string]$approvedPlan.decision.nextAction -ne 'execute-approved-external-retention-renewal'
) {
    throw 'The exact independent approval did not authorize the recorded external renewal procedure.'
}

Assert-Rejected -FailureMessage 'A passed custody chain audit was accepted as a retention-renewal trigger.' -Action {
    New-TestRetentionRenewalPlan `
        -TriggerEvidencePath $passedAuditPath `
        -OutputDirectory (Join-Path $testRoot 'invalid-trigger') `
        -ReferenceTime $planClock `
        -RequestedRetentionUntil $requestedRetentionUntil | Out-Null
}

Assert-Rejected -FailureMessage 'A retention-renewal plan accepted an inadequate extension.' -Action {
    New-TestRetentionRenewalPlan `
        -TriggerEvidencePath $triggerEvidencePath `
        -OutputDirectory (Join-Path $testRoot 'short-extension') `
        -ReferenceTime $planClock `
        -RequestedRetentionUntil $currentRetentionUntil.AddDays(364) `
        -ChangeId 'CHG-CUSTODY-RENEWAL-SHORT' | Out-Null
}

$originalPlan = [System.IO.File]::ReadAllText($planPath)
$planTamperingRejected = $false
try {
    $tamperedPlan = $originalPlan | ConvertFrom-Json -AsHashtable
    $tamperedPlan['renewal']['requestedRetentionUntilUtc'] = $currentRetentionUntil.AddDays(30).ToString('o')
    [System.IO.File]::WriteAllText($planPath, (($tamperedPlan | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-plan.ps1') `
            -PlanPath $planPath `
            -TriggerEvidencePath $triggerEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved `
            -ReferenceTimeUtc $approvedAt.ToString('o') 6>$null
    }
    catch {
        $planTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($planPath, $originalPlan, [System.Text.UTF8Encoding]::new($false))
}
if (-not $planTamperingRejected) {
    throw 'Production assurance retention-renewal plan tampering was not rejected.'
}

$originalTrigger = [System.IO.File]::ReadAllText($triggerEvidencePath)
$triggerTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($triggerEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-plan.ps1') `
            -PlanPath $planPath `
            -TriggerEvidencePath $triggerEvidencePath `
            -ExpectedProductionContext 'production-contract' `
            -RequiredState Approved `
            -ReferenceTimeUtc $approvedAt.ToString('o') 6>$null
    }
    catch {
        $triggerTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($triggerEvidencePath, $originalTrigger, [System.Text.UTF8Encoding]::new($false))
}
if (-not $triggerTamperingRejected) {
    throw 'Changed custody chain-audit trigger evidence was not rejected.'
}

Assert-Rejected -FailureMessage 'The retention-renewal gate accepted stale approval.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-gate.ps1') `
        -PlanPath $planPath `
        -TriggerEvidencePath $triggerEvidencePath `
        -ExpectedProductionContext 'production-contract' `
        -MaxPlanAgeMinutes 60 `
        -ReferenceTimeUtc $approvedAt.AddMinutes(61).ToString('o') 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-gate.ps1') `
    -PlanPath $planPath `
    -TriggerEvidencePath $triggerEvidencePath `
    -ExpectedProductionContext 'production-contract' `
    -ReferenceTimeUtc $approvedAt.ToString('o') 6>$null

Write-Host 'Production assurance retention-renewal planning contract passed.'
