[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EvidencePath,

    [string]$PlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [ValidateRange(5, 1440)]
    [int]$MaxEvidenceAgeMinutes = 60,

    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$resolvedEvidencePath = if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
    [System.IO.Path]::GetFullPath($EvidencePath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $EvidencePath))
}
if (-not $resolvedEvidencePath.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidencePath must be beneath the ignored .shieldward directory.'
}

$validationArguments = @{
    EvidencePath = $resolvedEvidencePath
    ExpectedProductionContext = $ExpectedProductionContext
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
    $validationArguments.PlanPath = $PlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-containment-evidence.ps1') @validationArguments 6>$null

$evidence = Get-Content -Raw -LiteralPath $resolvedEvidencePath | ConvertFrom-Json
$collectedAt = [DateTimeOffset]$evidence.collectedAtUtc
$evidenceAge = [DateTimeOffset]::UtcNow - $collectedAt.ToUniversalTime()
if ($evidenceAge.TotalMinutes -lt -5 -or $evidenceAge.TotalMinutes -gt $MaxEvidenceAgeMinutes) {
    throw "Production incident containment evidence is stale or future-dated; maximum age is $MaxEvidenceAgeMinutes minutes."
}
if (
    [string]$evidence.outcome -ne 'passed' -or
    [bool]$evidence.response.deadlineMet -ne $true -or
    [string]$evidence.response.executionStatus -ne 'completed' -or
    [bool]$evidence.traffic.matchesPlan -ne $true -or
    [string]$evidence.traffic.enforcementStatus -ne 'confirmed' -or
    [string]$evidence.verification.workloads -ne 'confirmed' -or
    [string]$evidence.verification.incidentRecord -ne 'updated' -or
    [string]$evidence.decision.nextAction -eq 'escalate-and-verify-containment'
) {
    throw 'Production incident containment is not proven; preserve evidence and escalate through the authoritative incident system.'
}

Write-Host "Production incident containment gate passed for incident $($evidence.incidentId) at $($evidence.traffic.observedPercent)% traffic."
Write-Host "Required next action: $($evidence.decision.nextAction)"
Write-Host 'This gate verifies external evidence; it does not authorize recovery or change production state.'
