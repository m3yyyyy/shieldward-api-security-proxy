[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery/recovery.json',
    [string]$ContainmentEvidencePath = '',
    [string]$ResponsePlanPath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovedBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalStatement,

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
$resolvedPlanPath = if ([System.IO.Path]::IsPathRooted($PlanPath)) {
    [System.IO.Path]::GetFullPath($PlanPath)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PlanPath))
}
if (-not $resolvedPlanPath.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PlanPath must be beneath the ignored .shieldward directory.'
}
if (-not (Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)) {
    throw "Production incident recovery plan is missing: $resolvedPlanPath"
}

$validationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Pending'
    CheckCluster = $CheckCluster
}
if (-not [string]::IsNullOrWhiteSpace($ContainmentEvidencePath)) {
    $validationArguments.ContainmentEvidencePath = $ContainmentEvidencePath
}
if (-not [string]::IsNullOrWhiteSpace($ResponsePlanPath)) {
    $validationArguments.ResponsePlanPath = $ResponsePlanPath
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') @validationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json -AsHashtable
if ([string]$plan['readiness']['outcome'] -ne 'passed') {
    throw 'Only a passed production incident recovery plan may be approved.'
}
$expectedStatement = [string]$plan['approval']['requiredStatement']
if (-not [string]::Equals($ApprovedBy, [string]$plan['approval']['owner'], [StringComparison]::Ordinal)) {
    throw "ApprovedBy must exactly match the recorded recovery owner '$($plan['approval']['owner'])'."
}
if (-not [string]::Equals($ApprovalStatement, $expectedStatement, [StringComparison]::Ordinal)) {
    throw "ApprovalStatement must exactly match: $expectedStatement"
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($sha256.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

$approvedAt = [DateTimeOffset]::UtcNow
$approvedAtUtc = $approvedAt.ToString('o')
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$approvalInput = "$($plan['integrityDigest'])|$ApprovedBy|$approvedAtUnixSeconds|$ApprovalStatement"
$plan['state'] = 'approved'
$plan['approval']['status'] = 'approved'
$plan['approval']['approvedBy'] = $ApprovedBy
$plan['approval']['approvedAtUtc'] = $approvedAtUtc
$plan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$plan['approval']['approvalStatement'] = $ApprovalStatement
$plan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput

[System.IO.File]::WriteAllText(
    $resolvedPlanPath,
    (($plan | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

$approvedValidationArguments = $validationArguments.Clone()
$approvedValidationArguments.RequiredState = 'Approved'
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-plan.ps1') @approvedValidationArguments 6>$null

Write-Host "Production incident recovery plan approved for incident $($plan['incidentId'])."
Write-Host "Authorized external boundary: $($plan['traffic']['currentPercent'])% to $($plan['traffic']['targetPercent'])%."
Write-Host 'The approval is a local audit record; the external incident and change systems remain authoritative.'
Write-Host 'No cluster or traffic changes were made.'
