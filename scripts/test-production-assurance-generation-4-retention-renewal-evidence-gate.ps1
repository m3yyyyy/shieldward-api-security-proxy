[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [ValidateRange(5, 1440)][int]$MaxEvidenceAgeMinutes = 60,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationArguments = @{
    EvidencePath = $EvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $validationArguments.PlanPath = $PlanPath
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-4-retention-renewal-evidence.ps1') @validationArguments 6>$null

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedEvidencePath = if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
    [System.IO.Path]::GetFullPath($EvidencePath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $EvidencePath))
}
$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json

$referenceNow = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
    }
    $referenceNow = ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
$collectedAt = ([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$observedRetentionUntil = ([DateTimeOffset]$evidence.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt = ([DateTimeOffset]$evidence.renewal.nextReviewDueAtUtc).ToUniversalTime()
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $referenceNow -ge $observedRetentionUntil -or
    $referenceNow -gt $nextReviewDueAt.AddMinutes(5)
) {
    throw 'Generation-4 production assurance retention-renewal evidence is stale, future-dated, expired, or overdue for the next custody review.'
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.execution.externalChangeStatus -ne 'completed' -or
    [string]$evidence.controls.retentionPolicy -ne 'active' -or
    [string]$evidence.controls.objectLock -ne 'enforced' -or
    [string]$evidence.controls.archiveInventory -ne 'complete' -or
    [string]$evidence.controls.encryption -ne 'verified' -or
    [string]$evidence.controls.accessControl -ne 'least-privilege' -or
    [string]$evidence.controls.restoreVerification -ne 'passed' -or
    [bool]$evidence.renewal.retentionExtended -ne $true -or
    [bool]$evidence.renewal.observedMeetsApprovedBoundary -ne $true -or
    [bool]$evidence.renewal.observedCoversNextReview -ne $true -or
    [bool]$evidence.decision.approvedPlanVerified -ne $true -or
    [bool]$evidence.decision.lineagePreserved -ne $true -or
    [bool]$evidence.decision.retentionRenewalProven -ne $true -or
    [string]$evidence.decision.nextAction -ne 'establish-generation-5-custody-review-baseline'
) {
    throw 'Generation-4 production assurance retention renewal is not proven; do not establish the generation-4 custody baseline.'
}

Write-Host "Generation-4 production assurance retention-renewal evidence gate passed for change $($evidence.changeId)."
Write-Host "Renewal sequence $($evidence.renewal.renewalSequence) is recorded through $($observedRetentionUntil.ToString('o'))."
Write-Host 'This gate proves only the recorded external result; it does not change retention, reset custody lineage, or change production.'

