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

function New-TestNextRenewedCustodyChainAudit {
    param(
        [Parameter(Mandatory)][string]$ChainHeadEvidencePath,
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][string]$RenewalEvidencePath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][DateTimeOffset]$AuditCompletedAt,
        [string]$ChainHeadGateStatus = 'passed',
        [string]$NextRenewedChainInventoryStatus = 'complete',
        [string]$BaselineStatus = 'verified',
        [string]$RenewalEvidenceStatus = 'verified',
        [string]$InheritedLineageStatus = 'preserved',
        [string]$EvidenceRetentionStatus = 'retained',
        [string]$IndependentReviewStatus = 'passed',
        [string]$AccessAuditStatus = 'passed',
        [string]$RestoreAuditStatus = 'passed'
    )

    $arguments = @{
        ChainHeadEvidencePath = $ChainHeadEvidencePath
        BaselinePath = $BaselinePath
        RenewalEvidencePath = $RenewalEvidencePath
        PlanPath = $PlanPath
        ExpectedProductionContext = 'production-contract'
        AuditCompletedAtUtc = $AuditCompletedAt
        ChainHeadGateStatus = $ChainHeadGateStatus
        NextRenewedChainInventoryStatus = $NextRenewedChainInventoryStatus
        BaselineStatus = $BaselineStatus
        RenewalEvidenceStatus = $RenewalEvidenceStatus
        InheritedLineageStatus = $InheritedLineageStatus
        EvidenceRetentionStatus = $EvidenceRetentionStatus
        IndependentReviewStatus = $IndependentReviewStatus
        AccessAuditStatus = $AccessAuditStatus
        RestoreAuditStatus = $RestoreAuditStatus
        ChainHeadGateReference = 'RENEWED-CHAIN-HEAD-GATE-001'
        NextRenewedChainInventoryReference = 'RENEWED-CHAIN-INVENTORY-001'
        BaselineReference = 'RENEWED-BASELINE-AUDIT-001'
        RenewalEvidenceReference = 'RENEWAL-EVIDENCE-AUDIT-001'
        InheritedLineageReference = 'ORIGINAL-LINEAGE-AUDIT-001'
        EvidenceRetentionReference = 'RENEWED-RETENTION-AUDIT-001'
        IndependentReviewReference = 'RENEWED-INDEPENDENT-REVIEW-001'
        AccessAuditReference = 'RENEWED-ACCESS-AUDIT-001'
        RestoreAuditReference = 'RENEWED-RESTORE-AUDIT-001'
        AuditedBy = 'Independent Renewed Custody Chain Auditor'
        MaxHeadEvidenceAgeHours = 2208
        MaxAuditAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'next-renewed-custody-chain-audit-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-retention-renewal-evidence-contract'
$baselineRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-baseline-contract'
$firstReviewRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-review-contract'
$recurringRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-recurring-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-next-renewed-custody-chain-audit-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-recurring-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/renewed-retention-renewal-CHG-CUSTODY-RENEWAL-002.json'
$renewalEvidencePath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'renewed-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$baselinePath = (Get-ChildItem -LiteralPath (Join-Path $baselineRoot 'passed') -Filter 'next-renewed-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$firstReviewPath = (Get-ChildItem -LiteralPath (Join-Path $firstReviewRoot 'passed') -Filter 'next-renewed-custody-review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$firstRecurringPath = (Get-ChildItem -LiteralPath (Join-Path $recurringRoot 'passed-first') -Filter 'next-renewed-custody-review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$headPath = (Get-ChildItem -LiteralPath (Join-Path $recurringRoot 'passed-second') -Filter 'next-renewed-custody-review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$head = Get-Content -Raw -LiteralPath $headPath | ConvertFrom-Json
$auditClock = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()
$commonArguments = @{
    ChainHeadEvidencePath = $headPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ReferenceTime = $auditClock
    AuditCompletedAt = $auditClock
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'passed'
$passedEvidencePath = New-TestNextRenewedCustodyChainAudit @caseArguments

$validationArguments = @{
    EvidencePath = $passedEvidencePath
    ChainHeadEvidencePath = $headPath
    BaselinePath = $baselinePath
    RenewalEvidencePath = $renewalEvidencePath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $auditClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @validationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-gate.ps1') @validationArguments 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [int]$passedEvidence.chain.initialSequence -ne 7 -or
    [int]$passedEvidence.chain.headSequence -ne 9 -or
    [int]$passedEvidence.chain.entryCount -ne 3 -or
    [bool]$passedEvidence.decision.chainVerified -ne $true -or
    [bool]$passedEvidence.decision.baselineVerified -ne $true -or
    [bool]$passedEvidence.decision.renewalVerified -ne $true -or
    [bool]$passedEvidence.decision.inheritedLineageVerified -ne $true -or
    [bool]$passedEvidence.decision.auditPassed -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-next-renewed-custody-reviews'
) {
    throw 'A healthy renewed custody chain did not produce a passed audit.'
}

$shortHead = Get-Content -Raw -LiteralPath $firstRecurringPath | ConvertFrom-Json
$shortClock = ([DateTimeOffset]$shortHead.collectedAtUtc).ToUniversalTime()
$shortArguments = $commonArguments.Clone()
$shortArguments.ChainHeadEvidencePath = $firstRecurringPath
$shortArguments.ReferenceTime = $shortClock
$shortArguments.AuditCompletedAt = $shortClock
$shortArguments.OutputDirectory = Join-Path $testRoot 'passed-short'
$shortEvidencePath = New-TestNextRenewedCustodyChainAudit @shortArguments
$shortEvidence = Get-Content -Raw -LiteralPath $shortEvidencePath | ConvertFrom-Json
if ([int]$shortEvidence.chain.initialSequence -ne 7 -or [int]$shortEvidence.chain.headSequence -ne 8 -or [int]$shortEvidence.chain.entryCount -ne 2) {
    throw 'A shorter renewed custody chain was not inventoried from its baseline sequence.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'incomplete-inventory'
$caseArguments.NextRenewedChainInventoryStatus = 'incomplete'
$incompletePath = New-TestNextRenewedCustodyChainAudit @caseArguments
$incomplete = Get-Content -Raw -LiteralPath $incompletePath | ConvertFrom-Json
if ([string]$incomplete.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'An incomplete renewed chain inventory did not require restoration and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'missing-baseline'
$caseArguments.BaselineStatus = 'missing'
$missingBaselinePath = New-TestNextRenewedCustodyChainAudit @caseArguments
$missingBaseline = Get-Content -Raw -LiteralPath $missingBaselinePath | ConvertFrom-Json
if ([string]$missingBaseline.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'A missing renewed baseline did not stop chain continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'changed-lineage'
$caseArguments.InheritedLineageStatus = 'changed'
$changedLineagePath = New-TestNextRenewedCustodyChainAudit @caseArguments
$changedLineage = Get-Content -Raw -LiteralPath $changedLineagePath | ConvertFrom-Json
if ([string]$changedLineage.decision.nextAction -ne 'preserve-chain-and-investigate') {
    throw 'Changed original lineage did not require chain preservation and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'retention-at-risk'
$caseArguments.EvidenceRetentionStatus = 'at-risk'
$retentionAtRiskPath = New-TestNextRenewedCustodyChainAudit @caseArguments
$retentionAtRisk = Get-Content -Raw -LiteralPath $retentionAtRiskPath | ConvertFrom-Json
if ([string]$retentionAtRisk.decision.nextAction -ne 'renew-retention-before-continuing') {
    throw 'At-risk renewed retention did not stop chain continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-access'
$caseArguments.AccessAuditStatus = 'failed'
$failedAccessPath = New-TestNextRenewedCustodyChainAudit @caseArguments
$failedAccess = Get-Content -Raw -LiteralPath $failedAccessPath | ConvertFrom-Json
if ([string]$failedAccess.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed renewed-chain access audit did not require restriction and investigation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-restore'
$caseArguments.RestoreAuditStatus = 'failed'
$failedRestorePath = New-TestNextRenewedCustodyChainAudit @caseArguments
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'Failed renewed-chain restore audit did not require repair and retesting.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'failed-governance'
$caseArguments.IndependentReviewStatus = 'failed'
$failedGovernancePath = New-TestNextRenewedCustodyChainAudit @caseArguments
$failedGovernance = Get-Content -Raw -LiteralPath $failedGovernancePath | ConvertFrom-Json
if ([string]$failedGovernance.decision.nextAction -ne 'stop-and-investigate-next-renewed-custody-chain') {
    throw 'Failed renewed-chain governance did not stop continuation.'
}

$caseArguments = $commonArguments.Clone()
$caseArguments.OutputDirectory = Join-Path $testRoot 'unknown'
$caseArguments.RenewalEvidenceStatus = 'unknown'
$unknownPath = New-TestNextRenewedCustodyChainAudit @caseArguments
$unknown = Get-Content -Raw -LiteralPath $unknownPath | ConvertFrom-Json
if ([string]$unknown.outcome -ne 'unknown' -or [string]$unknown.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown renewed custody chain-audit state did not fail closed.'
}

Assert-Rejected -FailureMessage 'The renewed custody chain audit accepted a non-recurring head.' -Action {
    $invalidHeadArguments = $commonArguments.Clone()
    $invalidHeadArguments.ChainHeadEvidencePath = $firstReviewPath
    $invalidHeadArguments.OutputDirectory = Join-Path $testRoot 'invalid-head'
    New-TestNextRenewedCustodyChainAudit @invalidHeadArguments | Out-Null
}

Assert-Rejected -FailureMessage 'The renewed custody chain-audit gate accepted incomplete inventory.' -Action {
    $failedGateArguments = $validationArguments.Clone()
    $failedGateArguments.EvidencePath = $incompletePath
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-gate.ps1') @failedGateArguments 6>$null
}

$wrongContextArguments = $validationArguments.Clone()
$wrongContextArguments.ExpectedProductionContext = 'wrong-production-context'
$wrongContextArguments.Remove('ReferenceTimeUtc')
Assert-Rejected -FailureMessage 'Renewed custody chain-audit evidence accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @wrongContextArguments 6>$null
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$evidenceTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['chain']['entryCount'] = [int]$tamperedEvidence['chain']['entryCount'] + 1
    [System.IO.File]::WriteAllText(
        $passedEvidencePath,
        (($tamperedEvidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @validationArguments 6>$null
    }
    catch {
        $evidenceTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $evidenceTamperingRejected) {
    throw 'Renewed custody chain-audit evidence tampering was not rejected.'
}

$originalHead = [System.IO.File]::ReadAllText($headPath)
$headTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($headPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @validationArguments 6>$null
    }
    catch {
        $headTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($headPath, $originalHead, [System.Text.UTF8Encoding]::new($false))
}
if (-not $headTamperingRejected) {
    throw 'Changed renewed custody chain head was not rejected.'
}

$originalInterior = [System.IO.File]::ReadAllText($firstRecurringPath)
$interiorTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($firstRecurringPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-evidence.ps1') @validationArguments 6>$null
    }
    catch {
        $interiorTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($firstRecurringPath, $originalInterior, [System.Text.UTF8Encoding]::new($false))
}
if (-not $interiorTamperingRejected) {
    throw 'Changed interior renewed custody review was not rejected.'
}

$staleGateArguments = $validationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $auditClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxEvidenceAgeMinutes = 60
Assert-Rejected -FailureMessage 'The renewed custody chain-audit gate accepted stale evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-gate.ps1') @staleGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-next-renewed-custody-chain-audit-gate.ps1') @validationArguments 6>$null

Write-Host 'Next renewed production assurance custody chain-audit contract passed.'
