# Recurring production assurance renewed custody reviews

Use this runbook after the first passed Chapter 62 renewed custody review.
Chapter 63 continues the renewed custody chain without resetting its sequence,
deadline, retention boundary, or original lineage.

This repository does not schedule reviews, inspect or mutate external storage,
renew retention, change access, perform restores, delete evidence, or change
production. External systems remain authoritative.

## 1. Preserve the recurring boundary

Every recurring renewed review must:

- use the exact passed Chapter 62 review or exact passed Chapter 63 predecessor;
- derive its sequence as the predecessor sequence plus one;
- use the predecessor's recorded next-review deadline;
- preserve the Chapter 61 baseline, Chapter 60 renewal evidence, original
  custody identity, and pre-renewal review-chain digest;
- revalidate archive availability, inventory, object lock, retention,
  encryption, least-privilege access, and restore verification;
- keep the following review inside renewed retention; and
- bind the exact predecessor file hash, integrity digest, link digest,
  sequences, deadline, and completion time into a new link digest.

Unknown states fail closed. A reference is not proof that an external control
remains effective.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-renewed-custody-recurring-contract.ps1
~~~

Its final line must be:

~~~text
Recurring production assurance renewed custody-review contract passed.
~~~

The contract uses only ignored `.shieldward` data. It proves two consecutive
recurring reviews and rejects late, missing, inactive, failed, unknown, stale,
wrong-context, failed-predecessor, and tampered evidence.

## 3. Select the exact predecessor

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-plan' -Filter 'retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-evidence' -Filter 'retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewedBaselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-baseline' -Filter 'renewed-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$previousReviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-review' -Filter 'renewed-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $renewalPlanFile -or $null -eq $renewalEvidenceFile -or $null -eq $renewedBaselineFile -or $null -eq $previousReviewFile) {
  throw 'The plan, renewal evidence, baseline, and previous renewed review are required.'
}
~~~

For later recurrences, select the newest passed record from
`.shieldward/production-assurance-renewed-custody-recurring` instead. Never edit generated JSON or skip an intermediate sequence.

## 4. Complete and record the external review

After completing the approved external review at the inherited deadline, set
authoritative non-secret references and record it:

~~~powershell
$newReviewArguments = @{
  PreviousReviewEvidencePath = $previousReviewFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  ReviewCompletedAtUtc = [DateTimeOffset]::UtcNow
  CompletionGraceHours = 24
  ArchiveAvailabilityStatus = 'available'
  EvidenceInventoryStatus = 'complete'
  ObjectLockStatus = 'enforced'
  RetentionPolicyStatus = 'active'
  EncryptionStatus = 'verified'
  AccessControlStatus = 'least-privilege'
  RestoreVerificationStatus = 'passed'
  PreviousReviewGateReference = 'REPLACE_WITH_PREVIOUS_GATE_RECORD'
  ScheduledReviewReference = 'REPLACE_WITH_REVIEW_RECORD'
  ArchiveInventoryReference = 'REPLACE_WITH_ARCHIVE_INVENTORY'
  ObjectLockReference = 'REPLACE_WITH_OBJECT_LOCK_PROOF'
  RetentionPolicyReference = 'REPLACE_WITH_RETENTION_POLICY_PROOF'
  EncryptionReference = 'REPLACE_WITH_ENCRYPTION_PROOF'
  AccessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW'
  RestoreTestReference = 'REPLACE_WITH_ISOLATED_RESTORE_TEST'
  ReviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
  MaxPreviousEvidenceAgeHours = 2208
  MaxReviewAgeMinutes = 60
}
& .\scripts\new-production-assurance-renewed-custody-recurring-evidence.ps1 @newReviewArguments
~~~

The immutable JSON output is written beneath
`.shieldward/production-assurance-renewed-custody-recurring`.

## 5. Validate and gate the review

~~~powershell
$recurringReviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-recurring' -Filter 'renewed-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$validationArguments = @{
  EvidencePath = $recurringReviewFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-custody-recurring-evidence.ps1 @validationArguments

$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-renewed-custody-recurring-gate.ps1 @gateArguments
~~~

A green gate proves only the recorded review. Preserve every predecessor and
continue from the exact latest passed artifact. A failed or unknown result
requires its recorded remediation and cannot support custody continuity.
