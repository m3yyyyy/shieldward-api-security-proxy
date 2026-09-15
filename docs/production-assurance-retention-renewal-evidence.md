# Production assurance retention-renewal execution evidence

Use this runbook immediately after the approved Chapter 59 procedure is
executed in the authoritative external archive system. Chapter 60 records and
independently validates whether retention was actually extended without
changing the original custody or review-chain identity.

These scripts do not renew retention, alter object lock, copy archive objects,
perform a restore, change access, delete evidence, or change production. They
only bind supplied external results to the exact approved plan. External
systems remain authoritative.

## 1. Preserve the execution-evidence boundary

Passed evidence requires all of these conditions:

- the exact Chapter 59 plan remains present, approved, fresh, and unchanged;
- execution follows approval and completes before the old retention expires;
- the externally observed retention date meets or exceeds the approved date;
- the renewed date covers the next custody review by the approved minimum;
- the original custody checksum, chain digest, and review-chain digest remain
  unchanged;
- the external change completed successfully;
- retention policy and immutable object lock are active and enforced;
- the complete archive inventory remains present and encrypted;
- access remains least privilege and an independent restore test passes; and
- every external result has a non-secret authoritative reference.

An approved plan is not execution evidence. A changed date without current
object-lock, inventory, access, and restore proof is not renewal evidence.
Unknown states fail closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-evidence-contract.ps1
```

Its final line must be:

```text
Production assurance retention-renewal execution evidence contract passed.
```

The test uses only ignored `.shieldward` data. It covers passed, failed,
insufficient, inactive, incomplete, overbroad, failed-restore, unknown,
pending-plan, stale, and tampered cases without contacting an archive.

## 3. Select and gate the exact approved plan

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-retention-renewal-plan' `
  -Filter 'retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $renewalPlanFile) {
  throw 'An approved production assurance retention-renewal plan was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-gate.ps1 `
  -PlanPath $renewalPlanFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60
```

Never edit generated JSON. The collector binds the approved file by path,
SHA-256, plan integrity digest, approval digest, and approval timestamp.

## 4. Gather authoritative execution results

```powershell
$executionCompletedAtUtc = [DateTimeOffset]'REPLACE_WITH_EXECUTION_COMPLETION_UTC'
$observedRetentionUntilUtc = [DateTimeOffset]'REPLACE_WITH_OBSERVED_RETENTION_UTC'
$externalChangeReference = 'REPLACE_WITH_COMPLETED_CHANGE_RESULT'
$retentionPolicyReference = 'REPLACE_WITH_RETENTION_POLICY_RESULT'
$objectLockReference = 'REPLACE_WITH_OBJECT_LOCK_RESULT'
$archiveInventoryReference = 'REPLACE_WITH_COMPLETE_ARCHIVE_INVENTORY'
$encryptionReference = 'REPLACE_WITH_ENCRYPTION_RESULT'
$accessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW_RESULT'
$restoreTestReference = 'REPLACE_WITH_INDEPENDENT_RESTORE_RESULT'
$executedBy = 'REPLACE_WITH_CUSTODY_OPERATOR'
$verifiedBy = 'REPLACE_WITH_INDEPENDENT_VERIFIER'
```

Use immutable identifiers or URLs without credentials, tokens, secret query
parameters, placeholders, or control characters.

## 5. Record the external result

```powershell
pwsh -NoProfile -File .\scripts\new-production-assurance-retention-renewal-evidence.ps1 `
  -PlanPath $renewalPlanFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ExecutionCompletedAtUtc $executionCompletedAtUtc `
  -ObservedRetentionUntilUtc $observedRetentionUntilUtc `
  -ExternalChangeStatus completed `
  -RetentionPolicyStatus active `
  -ObjectLockStatus enforced `
  -ArchiveInventoryStatus complete `
  -EncryptionStatus verified `
  -AccessControlStatus least-privilege `
  -RestoreVerificationStatus passed `
  -ExternalChangeReference $externalChangeReference `
  -RetentionPolicyReference $retentionPolicyReference `
  -ObjectLockReference $objectLockReference `
  -ArchiveInventoryReference $archiveInventoryReference `
  -EncryptionReference $encryptionReference `
  -AccessReviewReference $accessReviewReference `
  -RestoreTestReference $restoreTestReference `
  -ExecutedBy $executedBy `
  -VerifiedBy $verifiedBy `
  -MaxApprovedPlanAgeMinutes 60 `
  -MaxExecutionEvidenceAgeMinutes 60
```

The immutable JSON output is written beneath
`.shieldward/production-assurance-retention-renewal-evidence`.

## 6. Inspect and validate the evidence

```powershell
$renewalEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-retention-renewal-evidence' `
  -Filter 'retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $renewalEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-evidence.ps1 `
  -EvidencePath $renewalEvidenceFile.FullName `
  -PlanPath $renewalPlanFile.FullName `
  -ExpectedProductionContext $productionContext
```

Confirm `outcome` is `passed`, all three renewal booleans are true, every
control passes, `originalCustodyPreserved` and `retentionRenewalProven` are
true, and the action is `establish-renewed-custody-review-baseline`.

## 7. Apply the freshness gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-evidence-gate.ps1 `
  -EvidencePath $renewalEvidenceFile.FullName `
  -PlanPath $renewalPlanFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60
```

A green gate proves only the recorded external result. It does not change
retention, reset custody lineage, or authorize production changes.

## 8. Establish a renewed review baseline

Preserve the original custody and review chain. Do not edit its retention date
or append Chapter 60 evidence as though it were a normal recurring review.
Use the passed execution evidence to establish a separately validated renewed
custody-review baseline before scheduling or resuming later reviews.
