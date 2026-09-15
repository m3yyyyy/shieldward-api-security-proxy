[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestChainAuditEvidence {
    param(
        [Parameter(Mandatory)][string]$ChainHeadEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [string]$ChainHeadGateStatus = 'passed',
        [string]$ChainInventoryStatus = 'complete',
        [string]$EvidenceRetentionStatus = 'retained',
        [string]$IndependentReviewStatus = 'passed',
        [string]$AccessAuditStatus = 'passed'
    )

    $head = Get-Content -Raw -LiteralPath $ChainHeadEvidencePath | ConvertFrom-Json
    $arguments = @{
        ChainHeadEvidencePath = $ChainHeadEvidencePath
        ExpectedProductionContext = 'production-contract'
        AuditCompletedAtUtc = $ReferenceTime
        ChainHeadGateStatus = $ChainHeadGateStatus
        ChainInventoryStatus = $ChainInventoryStatus
        EvidenceRetentionStatus = $EvidenceRetentionStatus
        IndependentReviewStatus = $IndependentReviewStatus
        AccessAuditStatus = $AccessAuditStatus
        ChainHeadGateReference = 'CHAIN-AUDIT-HEAD-GATE-' + [string]$head.review.sequence
        ChainInventoryReference = 'CHAIN-AUDIT-INVENTORY-' + [string]$head.incidentId
        EvidenceRetentionReference = 'CHAIN-AUDIT-RETENTION-' + [string]$head.incidentId
        IndependentReviewReference = 'CHAIN-AUDIT-INDEPENDENT-' + [string]$head.incidentId
        AccessAuditReference = 'CHAIN-AUDIT-ACCESS-' + [string]$head.incidentId
        AuditedBy = 'Independent Assurance Chain Auditor'
        MaxHeadEvidenceAgeHours = 168
        MaxAuditAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-chain-audit-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'chain-audit-*.json' |
        Sort-Object Name -Descending |
        Select-Object -First 1).FullName
}

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

function Assert-AuditGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-gate.ps1') -EvidencePath $EvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$recurringSequenceTwoRoot = Join-Path $repoRoot '.shieldward/production-assurance-recurring-contract/passed-sequence-2'
$recurringSequenceThreeRoot = Join-Path $repoRoot '.shieldward/production-assurance-recurring-contract/passed-sequence-3'
$continuityRoot = Join-Path $repoRoot '.shieldward/production-assurance-continuity-contract/passed'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-chain-audit-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-recurring-contract.ps1') 6>$null

$sequenceTwoPath = (Get-ChildItem -LiteralPath $recurringSequenceTwoRoot -Filter 'review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$sequenceThreePath = (Get-ChildItem -LiteralPath $recurringSequenceThreeRoot -Filter 'review-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$continuityPath = (Get-ChildItem -LiteralPath $continuityRoot -Filter 'continuity-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$head = Get-Content -Raw -LiteralPath $sequenceThreePath | ConvertFrom-Json
$auditClock = ([DateTimeOffset]$head.collectedAtUtc).ToUniversalTime()

$passedEvidencePath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'passed-sequence-3') -ReferenceTime $auditClock
& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [bool]$passedEvidence.chain.verified -ne $true -or
    [int]$passedEvidence.chain.firstSequence -ne 1 -or
    [int]$passedEvidence.chain.headSequence -ne 3 -or
    [int]$passedEvidence.chain.entryCount -ne 3 -or
    [bool]$passedEvidence.decision.auditPassed -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'A healthy three-entry production assurance chain did not pass audit.'
}

$sequenceTwo = Get-Content -Raw -LiteralPath $sequenceTwoPath | ConvertFrom-Json
$sequenceTwoClock = ([DateTimeOffset]$sequenceTwo.collectedAtUtc).ToUniversalTime()
$sequenceTwoAuditPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceTwoPath -OutputDirectory (Join-Path $testRoot 'passed-sequence-2') -ReferenceTime $sequenceTwoClock
$sequenceTwoAudit = Get-Content -Raw -LiteralPath $sequenceTwoAuditPath | ConvertFrom-Json
if ([int]$sequenceTwoAudit.chain.entryCount -ne 2 -or [int]$sequenceTwoAudit.chain.headSequence -ne 2) {
    throw 'The chain auditor did not derive the correct sequence-2 inventory.'
}

Assert-Rejected -FailureMessage 'The chain audit accepted sequence 1 as a recurring chain head.' -Action {
    New-TestChainAuditEvidence -ChainHeadEvidencePath $continuityPath -OutputDirectory (Join-Path $testRoot 'invalid-head') -ReferenceTime $auditClock | Out-Null
}

$failedHeadGatePath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'failed-head-gate') -ReferenceTime $auditClock -ChainHeadGateStatus failed
$failedHeadGate = Get-Content -Raw -LiteralPath $failedHeadGatePath | ConvertFrom-Json
if ([string]$failedHeadGate.outcome -ne 'failed' -or [string]$failedHeadGate.decision.nextAction -ne 'revalidate-assurance-chain') {
    throw 'A failed chain-head gate did not require chain revalidation.'
}

$incompleteInventoryPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'incomplete-inventory') -ReferenceTime $auditClock -ChainInventoryStatus incomplete
$incompleteInventory = Get-Content -Raw -LiteralPath $incompleteInventoryPath | ConvertFrom-Json
if ([string]$incompleteInventory.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'An incomplete chain inventory did not require evidence restoration.'
}

$missingRetentionPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'missing-retention') -ReferenceTime $auditClock -EvidenceRetentionStatus missing
$missingRetention = Get-Content -Raw -LiteralPath $missingRetentionPath | ConvertFrom-Json
if ([string]$missingRetention.outcome -ne 'failed' -or [string]$missingRetention.decision.nextAction -ne 'restore-evidence-and-investigate') {
    throw 'Missing evidence retention did not fail the chain audit.'
}

$failedIndependentReviewPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'failed-independent-review') -ReferenceTime $auditClock -IndependentReviewStatus failed
$failedIndependentReview = Get-Content -Raw -LiteralPath $failedIndependentReviewPath | ConvertFrom-Json
if ([string]$failedIndependentReview.decision.nextAction -ne 'open-assurance-governance-incident') {
    throw 'A failed independent review did not require governance escalation.'
}

$failedAccessAuditPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'failed-access-audit') -ReferenceTime $auditClock -AccessAuditStatus failed
$failedAccessAudit = Get-Content -Raw -LiteralPath $failedAccessAuditPath | ConvertFrom-Json
if ([string]$failedAccessAudit.decision.nextAction -ne 'investigate-evidence-access') {
    throw 'A failed evidence access audit did not require investigation.'
}

$unknownAuditPath = New-TestChainAuditEvidence -ChainHeadEvidencePath $sequenceThreePath -OutputDirectory (Join-Path $testRoot 'unknown-audit') -ReferenceTime $auditClock -ChainInventoryStatus unknown
$unknownAudit = Get-Content -Raw -LiteralPath $unknownAuditPath | ConvertFrom-Json
if ([string]$unknownAudit.outcome -ne 'unknown' -or [string]$unknownAudit.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown chain inventory evidence did not fail closed.'
}

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$auditTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['chain']['entryCount'] = 2
    [System.IO.File]::WriteAllText($passedEvidencePath, (($tamperedEvidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null
    }
    catch {
        $auditTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $auditTamperingRejected) {
    throw 'Production assurance chain audit tampering was not rejected.'
}

$originalHead = [System.IO.File]::ReadAllText($sequenceThreePath)
$headTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($sequenceThreePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null
    }
    catch {
        $headTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($sequenceThreePath, $originalHead, [System.Text.UTF8Encoding]::new($false))
}
if (-not $headTamperingRejected) {
    throw 'Changed chain-head evidence was not rejected.'
}

$interiorPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ([string]$head.previousContinuityEvidence.relativePath)))
$originalInterior = [System.IO.File]::ReadAllText($interiorPath)
$interiorTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($interiorPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null
    }
    catch {
        $interiorTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($interiorPath, $originalInterior, [System.Text.UTF8Encoding]::new($false))
}
if (-not $interiorTamperingRejected) {
    throw 'Changed interior chain evidence was not rejected.'
}

Assert-AuditGateRejected -EvidencePath $passedEvidencePath -ReferenceTime $auditClock.AddMinutes(61) -FailureMessage 'The chain audit gate accepted stale evidence.'
& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $auditClock.ToString('o') 6>$null

Write-Host 'Production assurance chain audit evidence contract passed.'
