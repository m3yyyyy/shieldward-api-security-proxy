# Scheduled production assurance custody review evidence

Use this runbook for the first scheduled review of a passed production
assurance evidence-custody record. Chapter 55 proves the initial external
archive boundary. This chapter proves that the exact custody record remains
available, its evidence inventory is complete, its controls still pass, and
the next review is scheduled before retention expires.

This repository does not schedule a review, inspect external storage, renew
retention, change access, perform a restore, delete evidence, or change
production. External storage and records systems remain authoritative. A
passed gate proves only the supplied scheduled custody-review record.

## 1. Preserve the review boundary

A passed scheduled custody review requires all of these conditions:

- the exact passed Chapter 55 custody artifact is present and unchanged;
- the review completes no earlier than one hour before its recorded deadline
  and no later than the approved grace period;
- the archive is available and its evidence inventory is complete;
- object lock remains enforced and the retention policy remains active;
- encryption is verified and access remains least privilege;
- an isolated restore verification passes;
- remaining retention meets the approved minimum;
- the next review falls strictly before the retention deadline; and
- every external reference identifies current authoritative evidence.

A scheduled review record is not enforcement. References alone do not prove
that an archive is available, immutable, encrypted, access-restricted, or
restorable.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-review-contract.ps1
```

Its final line must be:

```text
Scheduled production assurance custody review contract passed.
```

The test uses only ignored `.shieldward` data. It checks late review,
missing archive, incomplete inventory, inadequate remaining retention, a next
review outside retention, failed encryption and restore, unknown state,
staleness, and tampering without contacting external storage.

## 3. Select the exact passed custody record

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$custodyEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-evidence-custody' `
  -Filter 'custody-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $custodyEvidenceFile) {
  throw 'A production assurance evidence custody artifact was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-gate.ps1 `
  -EvidencePath $custodyEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

Never edit generated JSON. The collector binds the custody artifact by
relative path, SHA-256 hash, integrity digest, archive chain digest, head
review sequence, and retention deadline.

## 4. Complete the scheduled external review

Use the approved external procedure to inspect the archive inventory, object
lock, retention, encryption, least-privilege access, and an isolated restore
test. The repository provides no command for those operations.

Record the exact values from the authoritative systems:

```powershell
$scheduledReviewDueAtUtc = [DateTimeOffset]::UtcNow
$reviewCompletedAtUtc = [DateTimeOffset]::UtcNow
$scheduledReviewReference = 'REPLACE_WITH_SCHEDULED_REVIEW_RECORD'
$archiveInventoryReference = 'REPLACE_WITH_ARCHIVE_INVENTORY'
$objectLockReference = 'REPLACE_WITH_OBJECT_LOCK_PROOF'
$retentionPolicyReference = 'REPLACE_WITH_RETENTION_POLICY_PROOF'
$encryptionReference = 'REPLACE_WITH_ENCRYPTION_PROOF'
$accessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW'
$restoreTestReference = 'REPLACE_WITH_ISOLATED_RESTORE_TEST'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
```

Use actual timestamps, identifiers, and URLs without credentials, tokens,
secret query parameters, placeholders, or control characters.

## 5. Record the completed custody review

```powershell
pwsh -NoProfile -File .\scripts\new-production-assurance-custody-review-evidence.ps1 `
  -CustodyEvidencePath $custodyEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ScheduledReviewDueAtUtc $scheduledReviewDueAtUtc `
  -ReviewCompletedAtUtc $reviewCompletedAtUtc `
  -CompletionGraceHours 24 `
  -NextReviewIntervalDays 90 `
  -MinimumRetentionRemainingDays 90 `
  -ArchiveAvailabilityStatus available `
  -EvidenceInventoryStatus complete `
  -ObjectLockStatus enforced `
  -RetentionPolicyStatus active `
  -EncryptionStatus verified `
  -AccessControlStatus least-privilege `
  -RestoreVerificationStatus passed `
  -ScheduledReviewReference $scheduledReviewReference `
  -ArchiveInventoryReference $archiveInventoryReference `
  -ObjectLockReference $objectLockReference `
  -RetentionPolicyReference $retentionPolicyReference `
  -EncryptionReference $encryptionReference `
  -AccessReviewReference $accessReviewReference `
  -RestoreTestReference $restoreTestReference `
  -ReviewedBy $reviewedBy `
  -MaxCustodyEvidenceAgeHours 2208 `
  -MaxReviewAgeMinutes 60 `
  -CheckCluster
```

The output is immutable JSON under
`.shieldward/production-assurance-custody-review`. The collector derives the
next deadline and the remaining-retention decision.

## 6. Inspect and validate the record

```powershell
$custodyReviewEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-review' `
  -Filter 'custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $custodyReviewEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-review-evidence.ps1 `
  -EvidencePath $custodyReviewEvidenceFile.FullName `
  -CustodyEvidencePath $custodyEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, `onTime` is true, every control passes,
remaining retention meets policy, the next review is inside retention, and
`custodyContinuityProven` is true.

## 7. Apply the freshness and next-review gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-review-gate.ps1 `
  -EvidencePath $custodyReviewEvidenceFile.FullName `
  -CustodyEvidencePath $custodyEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded custody review. It does not schedule,
retain, restore, delete, or change production evidence.

## 8. Continue scheduled assurance

Continue `docs/production-assurance-recurring.md` at every operational review
deadline. Complete the next custody review before the recorded custody-review
deadline and strictly before retention expires. A failed or unknown review
requires the recorded remediation and cannot support a custody-continuity
claim.

## 9. Continue the custody-review chain

After this first review passes, use
`docs/production-assurance-custody-recurring.md` for sequence 2 and every
later custody review. Each recurring artifact derives its sequence and
deadline from the exact previous passed review and preserves this review's
original custody and retention boundary.

Once recurring custody evidence exists, use
`docs/production-assurance-custody-chain-audit.md` for independent governance
checkpoints over the complete custody-review chain.
