[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PreviousReviewEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($PreviousReviewEvidencePath)) { $validationArguments.PreviousReviewEvidencePath = $PreviousReviewEvidencePath }
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) { $validationArguments.BaselinePath = $BaselinePath }
if (-not [string]::IsNullOrWhiteSpace($RenewalEvidencePath)) { $validationArguments.RenewalEvidencePath = $RenewalEvidencePath }
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $validationArguments.PlanPath = $PlanPath }
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) { $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc }
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-evidence.ps1') @validationArguments 6>$null

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
$nextReviewDueAt = ([DateTimeOffset]$evidence.schedule.nextReviewDueAtUtc).ToUniversalTime()
$retentionUntil = ([DateTimeOffset]$evidence.retention.untilUtc).ToUniversalTime()
$evidenceAge = $referenceNow - $collectedAt
if (
    $evidenceAge.TotalMinutes -lt -5 -or
    $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes -or
    $referenceNow -gt $nextReviewDueAt.AddMinutes(5) -or
    $referenceNow -ge $retentionUntil
) {
    throw 'Recurring generation-3 custody-review evidence is stale, future-dated, overdue, or outside retention.'
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [int]$evidence.nextRenewedCustodyBaseline.generation -ne 3 -or
    [int]$evidence.nextRenewedCustodyBaseline.renewalSequence -ne 2 -or
    [int]$evidence.review.sequence -lt 8 -or
    [string]$evidence.controls.archiveAvailability -ne 'available' -or
    [string]$evidence.controls.evidenceInventory -ne 'complete' -or
    [string]$evidence.controls.objectLock -ne 'enforced' -or
    [string]$evidence.controls.retentionPolicy -ne 'active' -or
    [string]$evidence.controls.encryption -ne 'verified' -or
    [string]$evidence.controls.accessControl -ne 'least-privilege' -or
    [string]$evidence.controls.restoreVerification -ne 'passed' -or
    [bool]$evidence.review.onTime -ne $true -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $true -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $true -or
    [bool]$evidence.decision.baselineLinkValid -ne $true -or
    [bool]$evidence.decision.predecessorLinkValid -ne $true -or
    [bool]$evidence.decision.inheritedLineagePreserved -ne $true -or
    [bool]$evidence.decision.custodyContinuityProven -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-next-renewed-custody-reviews'
) {
    throw 'Recurring generation-3 custody continuity is not proven; do not continue the review chain.'
}

Write-Host "Recurring generation-3 custody-review gate passed at sequence $($evidence.review.sequence)."
Write-Host "The next custody review is due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This gate proves only the recorded review; it does not schedule, retain, restore, delete, or change production evidence.'
