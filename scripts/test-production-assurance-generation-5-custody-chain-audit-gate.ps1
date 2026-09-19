[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$ChainHeadEvidencePath = '',
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
if (-not [string]::IsNullOrWhiteSpace($ChainHeadEvidencePath)) {
    $validationArguments.ChainHeadEvidencePath = $ChainHeadEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
    $validationArguments.BaselinePath = $BaselinePath
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
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-chain-audit-evidence.ps1') @validationArguments 6>$null

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
    throw 'The generation-5 custody chain-audit evidence is stale, future-dated, overdue, or outside generation-5 retention.'
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [string]$evidence.audit.chainHeadGateStatus -ne 'passed' -or
    [string]$evidence.audit.generation5ChainInventoryStatus -ne 'complete' -or
    [string]$evidence.audit.baselineStatus -ne 'verified' -or
    [string]$evidence.audit.renewalEvidenceStatus -ne 'verified' -or
    [string]$evidence.audit.inheritedLineageStatus -ne 'preserved' -or
    [string]$evidence.audit.evidenceRetentionStatus -ne 'retained' -or
    [string]$evidence.audit.independentReviewStatus -ne 'passed' -or
    [string]$evidence.audit.accessAuditStatus -ne 'passed' -or
    [string]$evidence.audit.restoreAuditStatus -ne 'passed' -or
    [bool]$evidence.schedule.nextReviewWithinRetention -ne $true -or
    [bool]$evidence.retention.remainingMeetsPolicy -ne $true -or
    [bool]$evidence.decision.chainVerified -ne $true -or
    [bool]$evidence.decision.baselineVerified -ne $true -or
    [bool]$evidence.decision.renewalVerified -ne $true -or
    [bool]$evidence.decision.inheritedLineageVerified -ne $true -or
    [bool]$evidence.decision.auditPassed -ne $true -or
    [string]$evidence.decision.nextAction -ne 'continue-generation-5-custody-reviews'
) {
    throw 'The generation-5 custody chain audit is not passed; do not continue generation-5 reviews.'
}

Write-Host "Generation-5 production assurance custody chain-audit gate passed through sequence $($evidence.chain.headSequence)."
Write-Host "Next generation-5 custody review is due at $($nextReviewDueAt.ToString('o'))."
Write-Host 'This gate proves only the recorded audit; it does not schedule, retain, restore, delete, or change production evidence.'
