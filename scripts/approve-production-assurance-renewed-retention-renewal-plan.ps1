[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [string]$TriggerEvidencePath = '',
    [string]$ChainHeadEvidencePath = '',
    [string]$BaselinePath = '',
    [string]$RenewalEvidencePath = '',
    [string]$PreviousRenewalPlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApprovedBy,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApprovalStatement,
    [string]$ApprovedAtUtc = ''
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
    throw "Renewed production assurance retention-renewal plan is missing: $resolvedPlanPath"
}

$approvedAt = [DateTimeOffset]::UtcNow
if (-not [string]::IsNullOrWhiteSpace($ApprovedAtUtc)) {
    if ($ExpectedProductionContext -ne 'production-contract') {
        throw 'ApprovedAtUtc is available only to the synthetic production-contract test context.'
    }
    $approvedAt = ([DateTimeOffset]$ApprovedAtUtc).ToUniversalTime()
}

$validationArguments = @{
    PlanPath = $resolvedPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Pending'
}
foreach ($optional in @(
    [pscustomobject]@{ Name = 'TriggerEvidencePath'; Value = $TriggerEvidencePath }
    [pscustomobject]@{ Name = 'ChainHeadEvidencePath'; Value = $ChainHeadEvidencePath }
    [pscustomobject]@{ Name = 'BaselinePath'; Value = $BaselinePath }
    [pscustomobject]@{ Name = 'RenewalEvidencePath'; Value = $RenewalEvidencePath }
    [pscustomobject]@{ Name = 'PreviousRenewalPlanPath'; Value = $PreviousRenewalPlanPath }
)) {
    if (-not [string]::IsNullOrWhiteSpace($optional.Value)) {
        $validationArguments[$optional.Name] = $optional.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($ApprovedAtUtc)) {
    $validationArguments.ReferenceTimeUtc = $approvedAt.ToString('o')
}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-plan.ps1') @validationArguments 6>$null

$plan = Get-Content -Raw -LiteralPath $resolvedPlanPath | ConvertFrom-Json -AsHashtable
$expectedStatement = [string]$plan['approval']['requiredStatement']
if (-not [string]::Equals($ApprovedBy, [string]$plan['authorities']['approvalOwner'], [StringComparison]::Ordinal)) {
    throw "ApprovedBy must exactly match the recorded approval owner '$($plan['authorities']['approvalOwner'])'."
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

$approvedAtUtcValue = $approvedAt.ToString('o')
$approvedAtUnixSeconds = $approvedAt.ToUnixTimeSeconds()
$approvalInput = "$($plan['integrityDigest'])|$ApprovedBy|$approvedAtUnixSeconds|$ApprovalStatement"
$plan['state'] = 'approved'
$plan['approval']['status'] = 'approved'
$plan['approval']['approvedBy'] = $ApprovedBy
$plan['approval']['approvedAtUtc'] = $approvedAtUtcValue
$plan['approval']['approvedAtUnixSeconds'] = $approvedAtUnixSeconds
$plan['approval']['approvalStatement'] = $ApprovalStatement
$plan['approval']['approvalDigest'] = Get-Sha256Text -Text $approvalInput
$plan['decision']['externalExecutionAuthorized'] = $true
$plan['decision']['nextAction'] = 'execute-approved-external-renewed-retention-renewal'

[System.IO.File]::WriteAllText(
    $resolvedPlanPath,
    (($plan | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

$approvedArguments = $validationArguments.Clone()
$approvedArguments.RequiredState = 'Approved'
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-plan.ps1') @approvedArguments 6>$null

Write-Host "Renewed production assurance retention-renewal plan approved for change $($plan['changeId'])."
Write-Host 'The approval is a local audit record; the external archive system remains authoritative.'
Write-Host 'No archive, retention, access, restore, scheduler, cluster, traffic, or rollback changes were made.'
