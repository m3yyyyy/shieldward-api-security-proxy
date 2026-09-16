# Production assurance renewed custody-review evidence

Use this runbook for the first custody review after a passed Chapter 61 renewed
baseline. Chapter 62 proves that the inherited review occurs at the exact
recorded sequence and deadline, the renewed archive controls still pass, and
the next review remains inside renewed retention.

This repository does not schedule a review, inspect or mutate external
storage, renew retention, change access, perform a restore, delete evidence, or
change production. External systems remain authoritative.

## 1. Preserve the renewed review boundary

A passed renewed custody review requires all of these conditions:

- the exact Chapter 61 baseline remains present, passed, and unchanged;
- the baseline still binds the exact Chapter 60 renewal evidence;
- the original custody identity and pre-renewal review-chain digest remain
  unchanged;
- the review sequence is exactly the inherited prior head plus one;
- the review deadline is taken from the baseline rather than supplied by an
  operator;
- the review completes no earlier than one hour before that deadline and no
  later than the approved grace period;
- archive availability, complete inventory, immutable lock, active retention,
  encryption, least-privilege access, and restore verification all pass;
- remaining renewed retention meets policy and contains the next review; and
- the new review-link digest binds the exact baseline, preserved lineage,
  sequence, deadline, and completion time.

A renewed baseline is not a completed review. Unknown states fail closed, and
references alone do not prove that controls remain effective.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-renewed-custody-review-contract.ps1
~~~

Its final line must be:

~~~text
Production assurance renewed custody-review evidence contract passed.
~~~

The test uses only ignored .shieldward data. It covers passed, late, missing,
inactive, failed-encryption, failed-restore, unknown, outside-retention, stale,
wrong-context, and tampered cases without contacting production or an archive.

## 3. Select and validate the exact baseline

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-plan' -Filter 'retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-evidence' -Filter 'retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewedBaselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-baseline' -Filter 'renewed-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $renewalPlanFile -or $null -eq $renewalEvidenceFile -or $null -eq $renewedBaselineFile) {
  throw 'The approved plan, renewal evidence, and renewed baseline are required.'
}

$baselineValidationArguments = @{
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-custody-baseline.ps1 @baselineValidationArguments
~~~

Never edit generated JSON. The Chapter 62 collector derives the review sequence,
scheduled deadline, renewed retention boundary, and preserved lineage from this
exact baseline.

## 4. Complete the external review

At the inherited deadline, follow the approved external procedure to inspect
the archive inventory, object lock, retention, encryption, least-privilege
access, and an isolated restore test.

Record only authoritative non-secret references:

~~~powershell
$reviewCompletedAtUtc = [DateTimeOffset]::UtcNow
$scheduledReviewReference = 'REPLACE_WITH_RENEWED_REVIEW_RECORD'
$archiveInventoryReference = 'REPLACE_WITH_ARCHIVE_INVENTORY'
$objectLockReference = 'REPLACE_WITH_OBJECT_LOCK_PROOF'
$retentionPolicyReference = 'REPLACE_WITH_RETENTION_POLICY_PROOF'
$encryptionReference = 'REPLACE_WITH_ENCRYPTION_PROOF'
$accessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW'
$restoreTestReference = 'REPLACE_WITH_ISOLATED_RESTORE_TEST'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
~~~

Do not include credentials, tokens, secret query parameters, placeholders, or
control characters.

## 5. Record the renewed custody review

~~~powershell
$newReviewArguments = @{
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  ReviewCompletedAtUtc = $reviewCompletedAtUtc
  CompletionGraceHours = 24
  NextReviewIntervalDays = 90
  MinimumRetentionRemainingDays = 90
  ArchiveAvailabilityStatus = 'available'
  EvidenceInventoryStatus = 'complete'
  ObjectLockStatus = 'enforced'
  RetentionPolicyStatus = 'active'
  EncryptionStatus = 'verified'
  AccessControlStatus = 'least-privilege'
  RestoreVerificationStatus = 'passed'
  ScheduledReviewReference = $scheduledReviewReference
  ArchiveInventoryReference = $archiveInventoryReference
  ObjectLockReference = $objectLockReference
  RetentionPolicyReference = $retentionPolicyReference
  EncryptionReference = $encryptionReference
  AccessReviewReference = $accessReviewReference
  RestoreTestReference = $restoreTestReference
  ReviewedBy = $reviewedBy
  MaxBaselineAgeHours = 2208
  MaxReviewAgeMinutes = 60
}
& .\scripts\new-production-assurance-renewed-custody-review-evidence.ps1 @newReviewArguments
~~~

The immutable JSON output is written beneath
.shieldward/production-assurance-renewed-custody-review.

## 6. Inspect and validate the review

~~~powershell
$renewedReviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-review' -Filter 'renewed-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

Get-Content -LiteralPath $renewedReviewFile.FullName

$reviewValidationArguments = @{
  EvidencePath = $renewedReviewFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-custody-review-evidence.ps1 @reviewValidationArguments
~~~

Confirm outcome is passed, the sequence equals the baseline next sequence,
onTime is true, the baseline and original-lineage links are valid, every
control passes, remaining retention meets policy, and the action is
continue-renewed-custody-reviews.

## 7. Apply the freshness gate

~~~powershell
$reviewGateArguments = $reviewValidationArguments.Clone()
$reviewGateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-renewed-custody-review-gate.ps1 @reviewGateArguments
~~~

A green gate proves only this recorded review. It does not schedule the next
review or alter retention, archives, access, restore state, production, or
rollback.

## 8. Continue the renewed chain

Preserve the exact Chapter 62 review, Chapter 61 baseline, Chapter 60 evidence,
Chapter 59 plan, original custody record, and pre-renewal review chain. The
next renewed review must bind this review-link digest and use its recorded next
deadline without resetting the sequence.

Failed or unknown evidence requires its recorded remediation and cannot support
a custody-continuity claim.
