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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-retention-renewal-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-renewed-custody-baseline-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-retention-renewal-evidence-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/retention-renewal-CHG-CUSTODY-RENEWAL-001.json'
$passedRenewalPath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedRenewalPath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'failed-change') -Filter 'retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$renewal = Get-Content -Raw -LiteralPath $passedRenewalPath | ConvertFrom-Json
$baselineClock = ([DateTimeOffset]$renewal.collectedAtUtc).ToUniversalTime().AddMinutes(1)
$outputDirectory = Join-Path $testRoot 'passed'

$newBaselineArguments = @{
    RenewalEvidencePath = $passedRenewalPath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    BaselineEstablishedAtUtc = $baselineClock
    BaselineReference = 'RENEWED-CUSTODY-BASELINE-001'
    EstablishedBy = 'Evidence Custody Owner'
    VerifiedBy = 'Independent Custody Verifier'
    MaxRenewalEvidenceAgeMinutes = 60
    MaxBaselineEstablishmentAgeMinutes = 60
    OutputDirectory = $outputDirectory
    ReferenceTimeUtc = $baselineClock.ToString('o')
    Force = $true
}
& (Join-Path $PSScriptRoot 'new-production-assurance-renewed-custody-baseline.ps1') @newBaselineArguments 6>$null
$baselinePath = (Get-ChildItem -LiteralPath $outputDirectory -Filter 'renewed-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName

$validationArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $passedRenewalPath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $baselineClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @validationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline-gate.ps1') @validationArguments 6>$null

$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
if (
    [string]$baseline.outcome -ne 'passed' -or
    [int]$baseline.renewedBaseline.generation -ne 2 -or
    [int]$baseline.renewedBaseline.renewalSequence -ne 1 -or
    [int]$baseline.renewedBaseline.previousHeadReviewSequence -ne [int]$renewal.rootCustody.headReviewSequence -or
    [int]$baseline.renewedBaseline.nextReviewSequence -ne ([int]$renewal.rootCustody.headReviewSequence + 1) -or
    [string]$baseline.originalCustody.sha256 -ne [string]$renewal.rootCustody.sha256 -or
    [string]$baseline.priorReviewChain.digest -ne [string]$renewal.rootCustody.reviewChainDigest -or
    [bool]$baseline.decision.originalCustodyPreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-scheduled-custody-reviews'
) {
    throw 'Passed renewal evidence did not establish the expected renewed custody-review baseline.'
}

$failedBaselineArguments = $newBaselineArguments.Clone()
$failedBaselineArguments.RenewalEvidencePath = $failedRenewalPath
$failedBaselineArguments.OutputDirectory = Join-Path $testRoot 'failed-renewal'
Assert-Rejected -FailureMessage 'A failed retention-renewal result established a renewed custody-review baseline.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-renewed-custody-baseline.ps1') @failedBaselineArguments 6>$null
}

$earlyBaselineArguments = $newBaselineArguments.Clone()
$earlyBaselineArguments.BaselineEstablishedAtUtc = ([DateTimeOffset]$renewal.collectedAtUtc).ToUniversalTime().AddMinutes(-1)
$earlyBaselineArguments.OutputDirectory = Join-Path $testRoot 'early-baseline'
Assert-Rejected -FailureMessage 'A baseline established before renewal evidence was accepted.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-renewed-custody-baseline.ps1') @earlyBaselineArguments 6>$null
}

$placeholderArguments = $newBaselineArguments.Clone()
$placeholderArguments.BaselineReference = 'REPLACE_WITH_BASELINE'
$placeholderArguments.OutputDirectory = Join-Path $testRoot 'placeholder'
Assert-Rejected -FailureMessage 'A placeholder baseline reference was accepted.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-renewed-custody-baseline.ps1') @placeholderArguments 6>$null
}

$wrongContextArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $passedRenewalPath
    PlanPath = $planPath
    ExpectedProductionContext = 'wrong-production-context'
}
Assert-Rejected -FailureMessage 'The renewed custody-review baseline accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @wrongContextArguments 6>$null
}

$originalBaseline = [System.IO.File]::ReadAllText($baselinePath)
$baselineTamperingRejected = $false
try {
    $tamperedBaseline = $originalBaseline | ConvertFrom-Json -AsHashtable
    $tamperedBaseline['renewedBaseline']['nextReviewSequence'] = [int]$tamperedBaseline['renewedBaseline']['nextReviewSequence'] + 1
    [System.IO.File]::WriteAllText(
        $baselinePath,
        (($tamperedBaseline | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @validationArguments 6>$null
    }
    catch {
        $baselineTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($baselinePath, $originalBaseline, [System.Text.UTF8Encoding]::new($false))
}
if (-not $baselineTamperingRejected) {
    throw 'Renewed custody-review baseline tampering was not rejected.'
}

$originalRenewal = [System.IO.File]::ReadAllText($passedRenewalPath)
$renewalTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedRenewalPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline.ps1') @validationArguments 6>$null
    }
    catch {
        $renewalTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedRenewalPath, $originalRenewal, [System.Text.UTF8Encoding]::new($false))
}
if (-not $renewalTamperingRejected) {
    throw 'Changed retention-renewal evidence was not rejected by the baseline.'
}

$staleGateArguments = $validationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $baselineClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxBaselineAgeMinutes = 60
Assert-Rejected -FailureMessage 'The renewed custody-review baseline gate accepted stale baseline evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline-gate.ps1') @staleGateArguments 6>$null
}

$overdueGateArguments = $validationArguments.Clone()
$overdueGateArguments.ReferenceTimeUtc = ([DateTimeOffset]$baseline.renewedBaseline.nextReviewDueAtUtc).ToUniversalTime().AddMinutes(6).ToString('o')
$overdueGateArguments.MaxBaselineAgeMinutes = 1440
Assert-Rejected -FailureMessage 'The renewed custody-review baseline gate accepted an overdue next review.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline-gate.ps1') @overdueGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-custody-baseline-gate.ps1') @validationArguments 6>$null

Write-Host 'Production assurance renewed custody-review baseline contract passed.'
