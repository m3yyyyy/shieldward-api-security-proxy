[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BaselinePath,
    [string]$RenewalEvidencePath = '',
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateRange(5, 1440)][int]$MaxBaselineAgeMinutes = 60,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationArguments = @{
    BaselinePath = $BaselinePath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) {
    $validationArguments.RenewalEvidencePath = $RenewalEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $validationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @validationArguments 6>$null

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedBaselinePath = if ([System.IO.Path]::IsPathRooted($BaselinePath)) {
    [System.IO.Path]::GetFullPath($BaselinePath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $BaselinePath))
}
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
$collectedAt = ([DateTimeOffset]$baseline.collectedAtUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$baseline.renewedBaseline.nextReviewDueAtUtc).ToUniversalTime()
$renewedRetentionUntil = ([DateTimeOffset]$baseline.renewedBaseline.renewedRetentionUntilUtc).ToUniversalTime()
$baselineAge = $referenceNow - $collectedAt
if (
    $baselineAge.TotalMinutes -lt -5 -or
    $baselineAge.TotalMinutes -gt $MaxBaselineAgeMinutes -or
    $referenceNow -gt $nextReviewDueAt.AddMinutes(5) -or
    $referenceNow -ge $renewedRetentionUntil
) {
    throw 'The renewed custody-review baseline is stale, future-dated, overdue for review, or outside renewed retention.'
}
if (
    [string]$baseline.outcome -ne 'passed' -or
    [bool]$baseline.renewalEvidence.retentionRenewalProven -ne $true -or
    [bool]$baseline.decision.renewalEvidenceVerified -ne $true -or
    [bool]$baseline.decision.originalCustodyPreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [bool]$baseline.decision.baselineEstablished -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-scheduled-custody-reviews'
) {
    throw 'The renewed custody-review baseline does not authorize resuming the existing review schedule.'
}

Write-Host "Production assurance renewed custody-review baseline gate passed for change $($baseline.changeId)."
Write-Host "Next review sequence $($baseline.renewedBaseline.nextReviewSequence) is due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This gate authorizes only resuming the existing review process; it does not schedule reviews or change production or archives.'
