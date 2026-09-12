[CmdletBinding()]
param(
    [string]$PlanPath = '.shieldward/production-incident-recovery-progressive/expansion.json',
    [string]$ExpansionEvidencePath = '',
    [string]$RecoveryPlanPath = '',
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

    [switch]$CheckCluster,
    [string]$ReferenceTimeUtc = ''
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
    throw "Production incident recovery progressive expansion plan is missing: $resolvedPlanPath"
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc) -and $ExpectedProductionContext -ne 'production-contract') {
    throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'
}

$validationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Pending'
    CheckCluster = $CheckCluster
}
foreach ($optionalPath in @(
    [pscustomobject]@{ Name = 'ExpansionEvidencePath'; Value = $ExpansionEvidencePath }
    [pscustomobject]@{ Name = 'RecoveryPlanPath'; Value = $RecoveryPlanPath }
    [pscustomobject]@{ Name = 'ContainmentEvidencePath'; Value = $ContainmentEvidencePath }
    [pscustomobject]@{ Name = 'ResponsePlanPath'; Value = $ResponsePlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optionalPath.Value)) {
        $validationArguments[$optionalPath.Name] = $optionalPath.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    $validationArguments.ReferenceTimeUtc = $ReferenceTimeUtc
}
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-plan.ps1') @validationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json -AsHashtable
if ([string]$plan['readiness']['outcome'] -ne 'passed') {
    throw 'Only a passed production recovery progressive expansion plan may be approved.'
}
$expectedStatement = [string]$plan['approval']['requiredStatement']
if (-not [string]::Equals($ApprovedBy, [string]$plan['approval']['owner'], [StringComparison]::Ordinal)) {
    throw "ApprovedBy must exactly match the recorded expansion owner '$($plan['approval']['owner'])'."
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

$approvedAt = if ([string]::IsNullOrWhiteSpace($ReferenceTimeUtc)) {
    [DateTimeOffset]::UtcNow
}
else {
    ([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}
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
& (Join-Path $PSScriptRoot 'test-production-incident-recovery-progressive-plan.ps1') @approvedValidationArguments 6>$null

Write-Host "Production recovery progressive expansion plan approved for incident $($plan['incidentId'])."
Write-Host "Authorized external boundary: $($plan['traffic']['currentPercent'])% to $($plan['traffic']['targetPercent'])%."
Write-Host 'The approval is a local audit record; the external incident and change systems remain authoritative.'
Write-Host 'No cluster or traffic changes were made.'

