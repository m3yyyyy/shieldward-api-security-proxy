[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Rejected {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$FailureMessage)

    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw $FailureMessage }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$planningRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-4-retention-renewal-contract'
$renewalRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-4-retention-renewal-evidence-contract'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-generation-5-custody-baseline-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-4-retention-renewal-evidence-contract.ps1') 6>$null

$planPath = Join-Path $planningRoot 'approved/generation-4-retention-renewal-CHG-CUSTODY-RENEWAL-004.json'
$passedRenewalPath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'passed') -Filter 'generation-4-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$failedRenewalPath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'failed-change') -Filter 'generation-4-retention-renewal-evidence-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$unknownRenewalPath = (Get-ChildItem -LiteralPath (Join-Path $renewalRoot 'unknown') -Filter 'generation-4-retention-renewal-evidence-*.json' |
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
    BaselineReference = 'GENERATION-4-CUSTODY-BASELINE-004'
    EstablishedBy = 'Generation-5 Evidence Custody Owner'
    VerifiedBy = 'Independent Generation-5 Baseline Verifier'
    MaxRenewalEvidenceAgeMinutes = 60
    MaxBaselineEstablishmentAgeMinutes = 60
    OutputDirectory = $outputDirectory
    ReferenceTimeUtc = $baselineClock.ToString('o')
    Force = $true
}
& (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-baseline.ps1') @newBaselineArguments 6>$null
$baselinePath = (Get-ChildItem -LiteralPath $outputDirectory -Filter 'generation-5-custody-baseline-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName

$validationArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $passedRenewalPath
    PlanPath = $planPath
    ExpectedProductionContext = 'production-contract'
    ReferenceTimeUtc = $baselineClock.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline.ps1') @validationArguments 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline-gate.ps1') @validationArguments 6>$null

$baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
if (
    [string]$baseline.outcome -ne 'passed' -or
    [int]$baseline.generation5Baseline.previousGeneration -ne 4 -or
    [int]$baseline.generation5Baseline.generation -ne 5 -or
    [int]$baseline.generation5Baseline.previousRenewalSequence -ne 3 -or
    [int]$baseline.generation5Baseline.renewalSequence -ne 4 -or
    [int]$baseline.generation5Baseline.previousHeadReviewSequence -ne 12 -or
    [int]$baseline.generation5Baseline.nextReviewSequence -ne 13 -or
    [string]$baseline.inheritedLineage.generation4BaselineSha256 -ne [string]$renewal.lineage.generation4BaselineSha256 -or
    [string]$baseline.inheritedLineage.previousRenewalEvidenceSha256 -ne [string]$renewal.lineage.previousRenewalEvidenceSha256 -or
    ($baseline.inheritedLineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -ne ($renewal.lineage.inheritedLineage | ConvertTo-Json -Depth 12 -Compress) -or
    [string]$baseline.inheritedLineage.generation4ReviewChainDigest -ne [string]$renewal.lineage.generation4ReviewChainDigest -or
    [bool]$baseline.decision.inheritedLineagePreserved -ne $true -or
    [bool]$baseline.decision.priorReviewChainPreserved -ne $true -or
    [string]$baseline.decision.nextAction -ne 'resume-generation-5-custody-review'
) {
    throw 'Passed fourth-renewal evidence did not establish the expected generation-5 custody baseline.'
}

$failedBaselineArguments = $newBaselineArguments.Clone()
$failedBaselineArguments.RenewalEvidencePath = $failedRenewalPath
$failedBaselineArguments.OutputDirectory = Join-Path $testRoot 'failed-renewal'
Assert-Rejected -FailureMessage 'Failed fourth-renewal evidence established a generation-5 custody baseline.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-baseline.ps1') @failedBaselineArguments 6>$null
}

$unknownBaselineArguments = $newBaselineArguments.Clone()
$unknownBaselineArguments.RenewalEvidencePath = $unknownRenewalPath
$unknownBaselineArguments.OutputDirectory = Join-Path $testRoot 'unknown-renewal'
Assert-Rejected -FailureMessage 'Unknown fourth-renewal evidence established a generation-5 custody baseline.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-baseline.ps1') @unknownBaselineArguments 6>$null
}

$earlyBaselineArguments = $newBaselineArguments.Clone()
$earlyBaselineArguments.BaselineEstablishedAtUtc = ([DateTimeOffset]$renewal.collectedAtUtc).ToUniversalTime().AddMinutes(-1)
$earlyBaselineArguments.OutputDirectory = Join-Path $testRoot 'early-baseline'
Assert-Rejected -FailureMessage 'A generation-5 baseline established before renewal evidence was accepted.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-baseline.ps1') @earlyBaselineArguments 6>$null
}

$placeholderArguments = $newBaselineArguments.Clone()
$placeholderArguments.BaselineReference = 'REPLACE_WITH_BASELINE'
$placeholderArguments.OutputDirectory = Join-Path $testRoot 'placeholder'
Assert-Rejected -FailureMessage 'A placeholder generation-5 baseline reference was accepted.' -Action {
    & (Join-Path $PSScriptRoot 'new-production-assurance-generation-5-custody-baseline.ps1') @placeholderArguments 6>$null
}

$wrongContextArguments = @{
    BaselinePath = $baselinePath
    RenewalEvidencePath = $passedRenewalPath
    PlanPath = $planPath
    ExpectedProductionContext = 'wrong-production-context'
}
Assert-Rejected -FailureMessage 'The generation-5 custody baseline accepted the wrong production context.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline.ps1') @wrongContextArguments 6>$null
}

$originalBaseline = [System.IO.File]::ReadAllText($baselinePath)
$baselineTamperingRejected = $false
try {
    $tamperedBaseline = $originalBaseline | ConvertFrom-Json -AsHashtable
    $tamperedBaseline['generation5Baseline']['nextReviewSequence'] = 14
    [System.IO.File]::WriteAllText(
        $baselinePath,
        (($tamperedBaseline | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline.ps1') @validationArguments 6>$null
    }
    catch { $baselineTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($baselinePath, $originalBaseline, [System.Text.UTF8Encoding]::new($false))
}
if (-not $baselineTamperingRejected) { throw 'Generation-5 custody baseline tampering was not rejected.' }

$originalRenewal = [System.IO.File]::ReadAllText($passedRenewalPath)
$renewalTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($passedRenewalPath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline.ps1') @validationArguments 6>$null
    }
    catch { $renewalTamperingRejected = $true }
}
finally {
    [System.IO.File]::WriteAllText($passedRenewalPath, $originalRenewal, [System.Text.UTF8Encoding]::new($false))
}
if (-not $renewalTamperingRejected) { throw 'Changed generation-4 retention-renewal evidence was not rejected by the generation-5 baseline.' }

$staleGateArguments = $validationArguments.Clone()
$staleGateArguments.ReferenceTimeUtc = $baselineClock.AddMinutes(61).ToString('o')
$staleGateArguments.MaxBaselineAgeMinutes = 60
Assert-Rejected -FailureMessage 'The generation-5 custody baseline gate accepted stale baseline evidence.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline-gate.ps1') @staleGateArguments 6>$null
}

$overdueGateArguments = $validationArguments.Clone()
$overdueGateArguments.ReferenceTimeUtc = ([DateTimeOffset]$baseline.generation5Baseline.nextReviewDueAtUtc).ToUniversalTime().AddMinutes(6).ToString('o')
$overdueGateArguments.MaxBaselineAgeMinutes = 1440
Assert-Rejected -FailureMessage 'The generation-5 custody baseline gate accepted an overdue next review.' -Action {
    & (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline-gate.ps1') @overdueGateArguments 6>$null
}

& (Join-Path $PSScriptRoot 'test-production-assurance-generation-5-custody-baseline-gate.ps1') @validationArguments 6>$null

Write-Host 'Generation-5 production assurance custody baseline contract passed.'

