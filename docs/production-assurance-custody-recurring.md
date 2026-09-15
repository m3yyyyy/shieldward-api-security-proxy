# Recurring production assurance custody review evidence

Use this runbook for custody-review sequence 2 and every later scheduled
external evidence review. Chapter 56 proves the first scheduled custody
review. This chapter turns that boundary into a tamper-evident chain: every
new review binds the exact previous passed artifact, derives the next sequence
and deadline, and preserves the original custody and retention boundary.

This repository does not schedule a review, inspect or alter an archive,
renew retention, change access, perform a restore, delete evidence, or change
production. External storage and records systems remain authoritative. These
scripts only collect, validate, and gate supplied evidence.

## 1. Preserve the recurring custody boundary

Every recurring custody review must satisfy all of these conditions:

- the exact previous passed custody-review artifact is present and unchanged;
- the review sequence is the previous sequence plus one;
- the expected deadline comes from the previous artifact and cannot be reset;
- completion is no earlier than one hour before that deadline and no later
  than the approved grace period;
- the original custody checksum, integrity digest, chain digest, head review
  sequence, and retention deadline remain unchanged;
- archive availability, inventory, object lock, retention, encryption,
  least-privilege access, and isolated restore verification pass;
- remaining retention meets the inherited minimum;
- the next review remains strictly inside the original retention window; and
- every external reference identifies current authoritative evidence.

Sequence numbers, deadlines, and retention boundaries are derived values. An
operator cannot skip a sequence, reset the clock, extend retention by editing
JSON, or use a failed review as the next predecessor.
Registration is not enforcement. A scheduled record alone does not prove
execution.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-recurring-contract.ps1
```

Its final line must be:

```text
Recurring production assurance custody review contract passed.
```

The test uses only ignored `.shieldward` data. It proves sequences 2 through
4, requires retention renewal at sequence 5, and checks late, missing,
inactive, overbroad, failed-restore, unknown, stale, failed-predecessor, and
tampered cases without contacting external storage.

## 3. Select the exact previous passed review

For sequence 2, use the passed Chapter 56 artifact. For every later sequence,
use the immediately preceding recurring custody-review artifact.

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$previousCustodyReviewEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-recurring' `
  -Filter 'custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $previousCustodyReviewEvidenceFile) {
  $previousCustodyReviewEvidenceFile = Get-ChildItem -LiteralPath `
    '.\.shieldward\production-assurance-custody-review' `
    -Filter 'custody-review-*.json' |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
}

if ($null -eq $previousCustodyReviewEvidenceFile) {
  throw 'No passed production assurance custody-review evidence was found.'
}

Get-Content -LiteralPath $previousCustodyReviewEvidenceFile.FullName
```

Never edit generated JSON. The collector binds the previous file by path,
SHA-256, integrity digest, evidence type, and sequence. It also carries the
unchanged root custody boundary through every later review.

## 4. Gather authoritative references

```powershell
$previousCustodyReviewGateReference = 'REPLACE_WITH_PREVIOUS_GREEN_GATE'
$scheduledReviewReference = 'REPLACE_WITH_CURRENT_SCHEDULED_REVIEW'
$archiveInventoryReference = 'REPLACE_WITH_CURRENT_ARCHIVE_INVENTORY'
$objectLockReference = 'REPLACE_WITH_CURRENT_OBJECT_LOCK_PROOF'
$retentionPolicyReference = 'REPLACE_WITH_CURRENT_RETENTION_PROOF'
$encryptionReference = 'REPLACE_WITH_CURRENT_ENCRYPTION_PROOF'
$accessReviewReference = 'REPLACE_WITH_CURRENT_ACCESS_REVIEW'
$restoreTestReference = 'REPLACE_WITH_CURRENT_RESTORE_TEST'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
```

Use immutable identifiers or URLs without credentials, tokens, secret query
parameters, placeholders, or control characters.

## 5. Record the completed recurring review

Use the actual completion time from the authoritative review record. The
collector derives the expected time, sequence, interval, next deadline, and
minimum remaining retention from the previous artifact.

```powershell
$reviewCompletedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-custody-recurring-evidence.ps1 `
  -PreviousCustodyReviewEvidencePath $previousCustodyReviewEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ReviewCompletedAtUtc $reviewCompletedAtUtc `
  -CompletionGraceHours 24 `
  -ArchiveAvailabilityStatus available `
  -EvidenceInventoryStatus complete `
  -ObjectLockStatus enforced `
  -RetentionPolicyStatus active `
  -EncryptionStatus verified `
  -AccessControlStatus least-privilege `
  -RestoreVerificationStatus passed `
  -PreviousCustodyReviewGateReference $previousCustodyReviewGateReference `
  -ScheduledReviewReference $scheduledReviewReference `
  -ArchiveInventoryReference $archiveInventoryReference `
  -ObjectLockReference $objectLockReference `
  -RetentionPolicyReference $retentionPolicyReference `
  -EncryptionReference $encryptionReference `
  -AccessReviewReference $accessReviewReference `
  -RestoreTestReference $restoreTestReference `
  -ReviewedBy $reviewedBy `
  -MaxPreviousEvidenceAgeHours 2208 `
  -MaxReviewAgeMinutes 60 `
  -CheckCluster
```

The output is immutable JSON under
`.shieldward/production-assurance-custody-recurring`.

## 6. Inspect and validate the artifact

```powershell
$recurringCustodyReviewEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-recurring' `
  -Filter 'custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recurringCustodyReviewEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-recurring-evidence.ps1 `
  -EvidencePath $recurringCustodyReviewEvidenceFile.FullName `
  -PreviousCustodyReviewEvidencePath $previousCustodyReviewEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm the sequence immediately follows the previous review, `outcome` is
`passed`, the root custody boundary is unchanged, the review completed on
time, all controls pass, retention remains sufficient, and
`custodyContinuityProven` is true.

## 7. Apply the freshness and next-review gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-recurring-gate.ps1 `
  -EvidencePath $recurringCustodyReviewEvidenceFile.FullName `
  -PreviousCustodyReviewEvidencePath $previousCustodyReviewEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded recurring custody-review chain. It does
not schedule, retain, restore, delete, or change production evidence.

## 8. Repeat without resetting custody

At the next deadline, use the artifact just created as
`PreviousCustodyReviewEvidencePath` and repeat this runbook. Late, failed, or
unknown reviews cannot become the predecessor of another review. When
remaining retention is insufficient or the following deadline no longer fits
inside retention, complete the approved external retention-renewal procedure
and establish new evidence before continuing.

## 9. Audit the complete custody-review chain

After at least one recurring review passes, use
`docs/production-assurance-custody-chain-audit.md` on the approved governance
schedule. Its read-only checkpoint inventories sequence 1 through the selected
head, verifies the unchanged root custody and retention boundary, and requires
independent retention, access, and restore audit evidence. It does not replace
the recurring review schedule.
