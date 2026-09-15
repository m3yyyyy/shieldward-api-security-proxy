[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$TriggerEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($TriggerEvidencePath)) {
    $validationArguments.TriggerEvidencePath = $TriggerEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-plan.ps1') @validationArguments 6>$null

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
$currentRetentionUntil = ([DateTimeOffset]$plan.custody.currentRetentionUntilUtc).ToUniversalTime()
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
    throw 'Production assurance retention-renewal approval is stale, future-dated, expired, or insufficient.'
}
if (
    [string]$plan.state -ne 'approved' -or
    [string]$plan.approval.status -ne 'approved' -or
    [bool]$plan.renewal.sufficientForNextReview -ne $true -or
    [bool]$plan.decision.eligibleForApproval -ne $true -or
    [bool]$plan.decision.externalExecutionAuthorized -ne $true -or
    [string]$plan.decision.nextAction -ne 'execute-approved-external-retention-renewal'
) {
    throw 'Production assurance retention renewal is not approved; do not change the external archive.'
}

Write-Host "Production assurance retention-renewal approval gate passed for change $($plan.changeId)."
Write-Host "Approved requested retention through $($requestedRetentionUntil.ToString('o'))."
Write-Host 'This gate authorizes only the recorded external procedure; it does not prove retention was renewed or change production.'
