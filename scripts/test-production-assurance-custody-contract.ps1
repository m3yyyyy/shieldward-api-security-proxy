[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-TestCustodyEvidence {
    param(
        [Parameter(Mandatory)][string]$ChainAuditEvidencePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [int]$RequiredRetentionDays = 365,
        [int]$RetentionDurationDays = 365,
        [string]$ArchivedAuditSha256 = '',
        [string]$ArchivedChainDigest = '',
        [string]$ArchiveWriteStatus = 'completed',
        [string]$ObjectLockStatus = 'enforced',
        [string]$RetentionPolicyStatus = 'active',
        [string]$EncryptionStatus = 'verified',
        [string]$AccessControlStatus = 'least-privilege',
        [string]$RestoreVerificationStatus = 'passed'
    )

    $audit = Get-Content -Raw -LiteralPath $ChainAuditEvidencePath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($ArchivedAuditSha256)) {
        $ArchivedAuditSha256 = (Get-FileHash -LiteralPath $ChainAuditEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ([string]::IsNullOrWhiteSpace($ArchivedChainDigest)) {
        $ArchivedChainDigest = [string]$audit.chain.digest
    }
    $arguments = @{
        ChainAuditEvidencePath = $ChainAuditEvidencePath
        ExpectedProductionContext = 'production-contract'
        ArchivedAtUtc = $ReferenceTime
        RetentionUntilUtc = $ReferenceTime.AddDays($RetentionDurationDays)
        RequiredRetentionDays = $RequiredRetentionDays
        ArchivedAuditSha256 = $ArchivedAuditSha256
        ArchivedChainDigest = $ArchivedChainDigest
        ArchiveWriteStatus = $ArchiveWriteStatus
        ObjectLockStatus = $ObjectLockStatus
        RetentionPolicyStatus = $RetentionPolicyStatus
        EncryptionStatus = $EncryptionStatus
        AccessControlStatus = $AccessControlStatus
        RestoreVerificationStatus = $RestoreVerificationStatus
        ArchiveObjectReference = 'CUSTODY-ARCHIVE-' + [string]$audit.chain.headSequence
        ObjectLockReference = 'CUSTODY-OBJECT-LOCK-' + [string]$audit.incidentId
        RetentionPolicyReference = 'CUSTODY-RETENTION-' + [string]$audit.incidentId
        EncryptionReference = 'CUSTODY-ENCRYPTION-' + [string]$audit.incidentId
        AccessReviewReference = 'CUSTODY-ACCESS-' + [string]$audit.incidentId
        RestoreTestReference = 'CUSTODY-RESTORE-' + [string]$audit.incidentId
        Custodian = 'Independent Evidence Custodian'
        MaxAuditEvidenceAgeHours = 168
        MaxCustodyEvidenceAgeMinutes = 60
        OutputDirectory = $OutputDirectory
        ReferenceTimeUtc = $ReferenceTime.ToUniversalTime().ToString('o')
        Force = $true
    }
    & (Join-Path $PSScriptRoot 'new-production-assurance-custody-evidence.ps1') @arguments 3>$null 6>$null

    return (Get-ChildItem -LiteralPath $OutputDirectory -Filter 'custody-*.json' |
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

function Assert-CustodyGateRejected {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceTime,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    Assert-Rejected -FailureMessage $FailureMessage -Action {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-gate.ps1') -EvidencePath $EvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $ReferenceTime.ToUniversalTime().ToString('o') 6>$null
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$auditRoot = Join-Path $repoRoot '.shieldward/production-assurance-chain-audit-contract/passed-sequence-3'
$testRoot = Join-Path $repoRoot '.shieldward/production-assurance-custody-contract'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

& (Join-Path $PSScriptRoot 'test-production-assurance-chain-audit-contract.ps1') 6>$null

$auditEvidencePath = (Get-ChildItem -LiteralPath $auditRoot -Filter 'chain-audit-*.json' |
    Sort-Object Name -Descending |
    Select-Object -First 1).FullName
$audit = Get-Content -Raw -LiteralPath $auditEvidencePath | ConvertFrom-Json
$custodyClock = ([DateTimeOffset]$audit.collectedAtUtc).ToUniversalTime()

$passedEvidencePath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'passed') -ReferenceTime $custodyClock
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $custodyClock.ToString('o') 6>$null
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $custodyClock.ToString('o') 6>$null

$passedEvidence = Get-Content -Raw -LiteralPath $passedEvidencePath | ConvertFrom-Json
if (
    [string]$passedEvidence.outcome -ne 'passed' -or
    [bool]$passedEvidence.archive.auditChecksumMatches -ne $true -or
    [bool]$passedEvidence.archive.chainDigestMatches -ne $true -or
    [bool]$passedEvidence.retention.meetsPolicy -ne $true -or
    [bool]$passedEvidence.decision.custodyConfirmed -ne $true -or
    [string]$passedEvidence.decision.nextAction -ne 'continue-scheduled-production-assurance'
) {
    throw 'Healthy external production assurance evidence custody did not pass.'
}

$checksumMismatchPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'checksum-mismatch') -ReferenceTime $custodyClock -ArchivedAuditSha256 ('0' * 64)
$checksumMismatch = Get-Content -Raw -LiteralPath $checksumMismatchPath | ConvertFrom-Json
if ([string]$checksumMismatch.outcome -ne 'failed' -or [string]$checksumMismatch.decision.nextAction -ne 'quarantine-and-rebuild-archive') {
    throw 'An archived audit checksum mismatch did not require archive quarantine.'
}

$chainDigestMismatchPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'chain-digest-mismatch') -ReferenceTime $custodyClock -ArchivedChainDigest ('f' * 64)
$chainDigestMismatch = Get-Content -Raw -LiteralPath $chainDigestMismatchPath | ConvertFrom-Json
if ([string]$chainDigestMismatch.decision.nextAction -ne 'quarantine-and-rebuild-archive') {
    throw 'An archived chain digest mismatch did not require archive quarantine.'
}

$shortRetentionPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'short-retention') -ReferenceTime $custodyClock -RequiredRetentionDays 365 -RetentionDurationDays 364
$shortRetention = Get-Content -Raw -LiteralPath $shortRetentionPath | ConvertFrom-Json
if ([bool]$shortRetention.retention.meetsPolicy -ne $false -or [string]$shortRetention.decision.nextAction -ne 'complete-compliant-archive-before-continuing') {
    throw 'An insufficient retention window did not block evidence custody.'
}

$failedWritePath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-write') -ReferenceTime $custodyClock -ArchiveWriteStatus failed
$failedWrite = Get-Content -Raw -LiteralPath $failedWritePath | ConvertFrom-Json
if ([string]$failedWrite.decision.nextAction -ne 'complete-compliant-archive-before-continuing') {
    throw 'A failed archive write did not require compliant archival.'
}

$missingObjectLockPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'missing-object-lock') -ReferenceTime $custodyClock -ObjectLockStatus not-enforced
$missingObjectLock = Get-Content -Raw -LiteralPath $missingObjectLockPath | ConvertFrom-Json
if ([string]$missingObjectLock.decision.nextAction -ne 'complete-compliant-archive-before-continuing') {
    throw 'Missing object lock did not block evidence custody.'
}

$failedEncryptionPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-encryption') -ReferenceTime $custodyClock -EncryptionStatus failed
$failedEncryption = Get-Content -Raw -LiteralPath $failedEncryptionPath | ConvertFrom-Json
if ([string]$failedEncryption.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Failed archive encryption did not require access restriction.'
}

$overbroadAccessPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'overbroad-access') -ReferenceTime $custodyClock -AccessControlStatus overbroad
$overbroadAccess = Get-Content -Raw -LiteralPath $overbroadAccessPath | ConvertFrom-Json
if ([string]$overbroadAccess.decision.nextAction -ne 'restrict-access-and-investigate') {
    throw 'Overbroad archive access did not require investigation.'
}

$failedRestorePath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'failed-restore') -ReferenceTime $custodyClock -RestoreVerificationStatus failed
$failedRestore = Get-Content -Raw -LiteralPath $failedRestorePath | ConvertFrom-Json
if ([string]$failedRestore.decision.nextAction -ne 'repair-archive-and-repeat-restore-test') {
    throw 'A failed restore test did not require archive repair.'
}

$unknownCustodyPath = New-TestCustodyEvidence -ChainAuditEvidencePath $auditEvidencePath -OutputDirectory (Join-Path $testRoot 'unknown') -ReferenceTime $custodyClock -ObjectLockStatus unknown
$unknownCustody = Get-Content -Raw -LiteralPath $unknownCustodyPath | ConvertFrom-Json
if ([string]$unknownCustody.outcome -ne 'unknown' -or [string]$unknownCustody.decision.nextAction -ne 'investigate-and-refresh-evidence') {
    throw 'Unknown external custody evidence did not fail closed.'
}

Assert-CustodyGateRejected -EvidencePath $shortRetentionPath -ReferenceTime $custodyClock -FailureMessage 'The custody gate accepted insufficient retention.'

$originalEvidence = [System.IO.File]::ReadAllText($passedEvidencePath)
$custodyTamperingRejected = $false
try {
    $tamperedEvidence = $originalEvidence | ConvertFrom-Json -AsHashtable
    $tamperedEvidence['decision']['custodyConfirmed'] = $false
    [System.IO.File]::WriteAllText($passedEvidencePath, (($tamperedEvidence | ConvertTo-Json -Depth 9) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $custodyClock.ToString('o') 6>$null
    }
    catch {
        $custodyTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($passedEvidencePath, $originalEvidence, [System.Text.UTF8Encoding]::new($false))
}
if (-not $custodyTamperingRejected) {
    throw 'Evidence custody record tampering was not rejected.'
}

$originalAudit = [System.IO.File]::ReadAllText($auditEvidencePath)
$auditTamperingRejected = $false
try {
    [System.IO.File]::AppendAllText($auditEvidencePath, ' ')
    try {
        & (Join-Path $PSScriptRoot 'test-production-assurance-custody-evidence.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $custodyClock.ToString('o') 6>$null
    }
    catch {
        $auditTamperingRejected = $true
    }
}
finally {
    [System.IO.File]::WriteAllText($auditEvidencePath, $originalAudit, [System.Text.UTF8Encoding]::new($false))
}
if (-not $auditTamperingRejected) {
    throw 'Changed chain audit evidence was not rejected by custody validation.'
}

Assert-CustodyGateRejected -EvidencePath $passedEvidencePath -ReferenceTime $custodyClock.AddMinutes(61) -FailureMessage 'The custody gate accepted stale evidence.'
& (Join-Path $PSScriptRoot 'test-production-assurance-custody-gate.ps1') -EvidencePath $passedEvidencePath -ExpectedProductionContext 'production-contract' -ReferenceTimeUtc $custodyClock.ToString('o') 6>$null

Write-Host 'Production assurance evidence custody contract passed.'
