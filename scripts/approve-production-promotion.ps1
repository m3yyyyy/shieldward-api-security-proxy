[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production/promotion.json',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovedBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApprovalStatement
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
    throw "Production promotion plan is missing: $resolvedPlanPath"
}

$validationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Pending'
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $validationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') @validationArguments | Out-Null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json -AsHashtable
$expectedStatement = [string]$plan['approval']['requiredStatement']
if (-not [string]::Equals($ApprovedBy, [string]$plan['approval']['owner'], [StringComparison]::Ordinal)) {
    throw "ApprovedBy must exactly match the recorded approval owner '$($plan['approval']['owner'])'."
}
if (-not [string]::Equals($ApprovalStatement, $expectedStatement, [StringComparison]::Ordinal)) {
    throw "ApprovalStatement must exactly match: $expectedStatement"
}

function Get-Sha256Text {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

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

$approvedValidationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $approvedValidationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-production-promotion-plan.ps1') @approvedValidationArguments | Out-Null

Write-Host "Production promotion plan approved for change $($plan['changeId'])."
Write-Host 'The approval is a local audit record; the external change system remains authoritative.'
Write-Host 'No cluster changes were made.'
