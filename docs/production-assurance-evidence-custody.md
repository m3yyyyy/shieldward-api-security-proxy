# Production assurance evidence custody

Use this runbook after a production assurance chain-audit checkpoint passes.
Chapter 54 proves the retained local review lineage. This chapter records
whether an external archive contains the exact audit checksum and chain
digest, meets the required retention window, and has current storage-control
and restore evidence.

This repository does not upload or delete an archive, enable object lock,
configure retention or encryption, change access, or perform a restore.
External storage and records systems remain authoritative. A passed gate proves
only the supplied custody record.

## 1. Preserve the custody boundary

A passed custody record requires all of these conditions:

- the exact passed Chapter 54 audit artifact is present and unchanged;
- the externally recorded audit SHA-256 equals the local audit file hash;
- the externally recorded chain digest equals the audited chain digest;
- the archive write is completed;
- immutable object lock is recorded as enforced;
- the retention policy is active and its deadline meets the required duration;
- encryption is verified;
- archive access is least privilege;
- an isolated restore verification passes; and
- every external reference identifies current authoritative evidence.

Archive registration is not enforcement. An object identifier or retention
label alone does not prove object lock, encryption, restricted access, or
restorability.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-contract.ps1
```

Its final line must be:

```text
Production assurance evidence custody contract passed.
```

The test uses only ignored `.shieldward` data. It checks checksum and chain
digest mismatches, inadequate retention, missing object lock, failed writes,
encryption, access and restore failures, unknown state, stale evidence, and
tampering without contacting external storage.

## 3. Select the passed chain audit

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$chainAuditEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-chain-audit' `
  -Filter 'chain-audit-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $chainAuditEvidenceFile) {
  throw 'A production assurance chain audit artifact was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-chain-audit-gate.ps1 `
  -EvidencePath $chainAuditEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster

$chainAudit = Get-Content -Raw -LiteralPath `
  $chainAuditEvidenceFile.FullName | ConvertFrom-Json
$localAuditSha256 = (Get-FileHash -LiteralPath `
  $chainAuditEvidenceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$localChainDigest = [string]$chainAudit.chain.digest
```

Never edit generated JSON.

## 4. Complete the external custody operation

Through the approved external storage procedure, archive the audit checkpoint
and its retained review-chain objects. Enable the approved immutable retention,
encryption, and least-privilege controls, then perform an isolated restore
verification. The repository provides no command for these operations.

Record the exact values returned by those authoritative systems:

```powershell
$archivedAtUtc = [DateTimeOffset]::UtcNow
$retentionUntilUtc = $archivedAtUtc.AddDays(365)
$requiredRetentionDays = 365
$archivedAuditSha256 = $localAuditSha256
$archivedChainDigest = $localChainDigest

$archiveObjectReference = 'REPLACE_WITH_IMMUTABLE_ARCHIVE_OBJECT'
$objectLockReference = 'REPLACE_WITH_OBJECT_LOCK_PROOF'
$retentionPolicyReference = 'REPLACE_WITH_RETENTION_POLICY_PROOF'
$encryptionReference = 'REPLACE_WITH_ENCRYPTION_PROOF'
$accessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW'
$restoreTestReference = 'REPLACE_WITH_ISOLATED_RESTORE_TEST'
$custodian = 'REPLACE_WITH_ACCOUNTABLE_CUSTODIAN'
```

Use actual timestamps, checksums, digests, identifiers, and URLs without
credentials, tokens, secret query parameters, placeholders, or control
characters.

## 5. Record custody evidence

```powershell
pwsh -NoProfile -File .\scripts\new-production-assurance-custody-evidence.ps1 `
  -ChainAuditEvidencePath $chainAuditEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ArchivedAtUtc $archivedAtUtc `
  -RetentionUntilUtc $retentionUntilUtc `
  -RequiredRetentionDays $requiredRetentionDays `
  -ArchivedAuditSha256 $archivedAuditSha256 `
  -ArchivedChainDigest $archivedChainDigest `
  -ArchiveWriteStatus completed `
  -ObjectLockStatus enforced `
  -RetentionPolicyStatus active `
  -EncryptionStatus verified `
  -AccessControlStatus least-privilege `
  -RestoreVerificationStatus passed `
  -ArchiveObjectReference $archiveObjectReference `
  -ObjectLockReference $objectLockReference `
  -RetentionPolicyReference $retentionPolicyReference `
  -EncryptionReference $encryptionReference `
  -AccessReviewReference $accessReviewReference `
  -RestoreTestReference $restoreTestReference `
  -Custodian $custodian `
  -MaxAuditEvidenceAgeHours 168 `
  -MaxCustodyEvidenceAgeMinutes 60 `
  -CheckCluster
```

The output is immutable JSON under
`.shieldward/production-assurance-evidence-custody`.

## 6. Inspect and validate the record

```powershell
$custodyEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-evidence-custody' `
  -Filter 'custody-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $custodyEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-evidence.ps1 `
  -EvidencePath $custodyEvidenceFile.FullName `
  -ChainAuditEvidencePath $chainAuditEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, both digest comparisons are true,
retention meets policy, every storage control passes, and
`custodyConfirmed` is true.

## 7. Apply the freshness and retention gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-gate.ps1 `
  -EvidencePath $custodyEvidenceFile.FullName `
  -ChainAuditEvidencePath $chainAuditEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only recorded external custody evidence. It does not upload,
lock, retain, restore, or delete evidence, and it does not replace scheduled
production assurance.

## 8. Continue assurance and custody reviews

Continue `docs/production-assurance-recurring.md` at every scheduled
deadline. Repeat the chain audit and custody review according to the approved
governance schedule. A failed or unknown custody record requires the recorded
remediation before it can support an audit claim.
