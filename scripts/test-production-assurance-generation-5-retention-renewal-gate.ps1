[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$TriggerEvidencePath = '',
    [string]$ChainHeadEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PreviousRenewalPlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateRange(5, 1440)][int]$MaxPlanAgeMinutes = 60,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationArguments = @{
    PlanPath = $PlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
}
foreach ($optional in @(
    [pscustomobject]@{ Name = 'TriggerEvidencePath'; Value = $TriggerEvidencePath }
    [pscustomobject]@{ Name = 'ChainHeadEvidencePath'; Value = $ChainHeadEvidencePath }
    [pscustomobject]@{ Name = 'BaselinePath'; Value = $BaselinePath }
    [pscustomobject]@{ Name = 'RenewalEvidencePath'; Value = $RenewalEvidencePath }
    [pscustomobject]@{ Name = 'PreviousRenewalPlanPath'; Value = $PreviousRenewalPlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optional.Value)) {
        $validationArguments[$optional.Name] = $optional.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-retention-renewal-plan.ps1') @validationArguments 6>$null

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedPlanPath = if ([System.IO.Path]::IsPathRooted($PlanPath)) {
    [System.IO.Path]::GetFullPath($PlanPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PlanPath))
}
$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json
$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
$generatedAt = ([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$approvedAt = ([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
$currentRetentionUntil = ([DateTimeOffset]$plan.renewal.currentRetentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil = ([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime()
$planAge = $referenceNow - $generatedAt
$approvalAge = $referenceNow - $approvedAt
if (
    $planAge.TotalMinutes -lt -5 -or
    $planAge.TotalMinutes -gt $MaxPlanAgeMinutes -or
    $approvalAge.TotalMinutes -lt -5 -or
    $approvalAge.TotalMinutes -gt $MaxPlanAgeMinutes -or
    $referenceNow -ge $currentRetentionUntil -or
    $requestedRetentionUntil -le $currentRetentionUntil -or
    $requestedRetentionUntil -le $nextReviewDueAt
) {
    throw 'Generation-5 production assurance retention-renewal approval is stale, future-dated, expired, or insufficient.'
}
if (
    [string]$plan.state -ne 'approved' -or
    [string]$plan.approval.status -ne 'approved' -or
    [bool]$plan.renewal.sufficientForNextReview -ne $true -or
    [bool]$plan.decision.lineagePreserved -ne $true -or
    [bool]$plan.decision.eligibleForApproval -ne $true -or
    [bool]$plan.decision.externalExecutionAuthorized -ne $true -or
    [string]$plan.decision.nextAction -ne 'execute-approved-external-generation-5-retention-renewal'
) {
    throw 'Generation-5 retention renewal is not approved; do not change the external archive.'
}

Write-Host "Generation-5 production assurance retention-renewal approval gate passed for change $($plan.changeId)."
Write-Host "Approved renewal sequence $($plan.renewal.renewalSequence) through $($requestedRetentionUntil.ToString('o'))."
Write-Host 'This gate authorizes only the recorded procedure; it does not prove retention changed or modify production.'


