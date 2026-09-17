# Recurring next-renewed production assurance custody reviews

This procedure continues generation-3 custody reviews after the passed Chapter
68 sequence-7 artifact. Every review must bind the exact latest passed
predecessor, derive the next sequence and deadline, revalidate the external
archive controls, and preserve the complete original and renewed lineage.

The scripts record and verify evidence only. They do not schedule reviews,
change retention or object lock, modify archive access, perform restores,
change Kubernetes or traffic, or mutate production workloads.

## Safety boundary

- The first recurring review accepts only the exact passed sequence-7 artifact.
- Every later review accepts only the exact latest passed recurring predecessor.
- Sequence 8 must follow 7, sequence 9 must follow 8, and no sequence may be
  skipped, repeated, or reset.
- Reuse the predecessor's review interval, retention boundary, minimum remaining
  retention, generation 3, renewal sequence 2, and inherited lineage.
- Require available archives, complete inventory, enforced object lock, active
  retention, verified encryption, least-privilege access, and a passed restore.
- Treat late, missing, failed, unknown, stale, wrong-context, substituted, or
  altered evidence as a closed gate.
- Never edit generated JSON. Regenerate it from authoritative observations.

## 1. Verify the synthetic contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-next-renewed-custody-recurring-contract.ps1
```

The contract reconstructs the complete prior chain, proves sequences 8 and 9,
and verifies rejection of unsafe results, failed predecessors, stale evidence,
wrong contexts, and tampering.

## 2. Locate the exact predecessor

For sequence 8, use the passed Chapter 68 artifact. For sequence 9 and later,
use the latest passed artifact produced by this procedure.

```powershell
$productionContext = 'REPLACE_WITH_APPROVED_PRODUCTION_CONTEXT'
$previousReviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-next-renewed-custody-review' -Filter 'next-renewed-custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$baselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-next-renewed-custody-baseline' -Filter 'next-renewed-custody-baseline-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-retention-renewal-evidence' -Filter 'renewed-retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-retention-renewal-plan' -Filter 'renewed-retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
```

After the first recurring review, point `$previousReviewFile` at the latest
passed file beneath
`.shieldward/production-assurance-next-renewed-custody-recurring`.

## 3. Record the next review

```powershell
$reviewArguments = @{
  PreviousReviewEvidencePath = $previousReviewFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
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
  PreviousReviewGateReference = 'REPLACE_WITH_PREDECESSOR_GATE_REFERENCE'
  ScheduledReviewReference = 'REPLACE_WITH_REVIEW_REFERENCE'
  ArchiveInventoryReference = 'REPLACE_WITH_INVENTORY_REFERENCE'
  ObjectLockReference = 'REPLACE_WITH_OBJECT_LOCK_REFERENCE'
  RetentionPolicyReference = 'REPLACE_WITH_RETENTION_REFERENCE'
  EncryptionReference = 'REPLACE_WITH_ENCRYPTION_REFERENCE'
  AccessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW_REFERENCE'
  RestoreTestReference = 'REPLACE_WITH_RESTORE_TEST_REFERENCE'
  ReviewedBy = 'REPLACE_WITH_INDEPENDENT_REVIEWER'
}
& .\scripts\new-production-assurance-next-renewed-custody-recurring-evidence.ps1 @reviewArguments
```

Use `unknown` whenever a control cannot be proven. Never infer a passing state.

## 4. Validate and gate the review

```powershell
$reviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-next-renewed-custody-recurring' -Filter 'next-renewed-custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

$validationArguments = @{
  EvidencePath = $reviewFile.FullName
  PreviousReviewEvidencePath = $previousReviewFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-next-renewed-custody-recurring-evidence.ps1 @validationArguments

$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-next-renewed-custody-recurring-gate.ps1 @gateArguments
```

Only a fresh passed gate may become the next predecessor. Chapter 70 may audit
the complete generation-3 chain at an approved governance checkpoint, but an
audit must not replace or reschedule any custody review.
