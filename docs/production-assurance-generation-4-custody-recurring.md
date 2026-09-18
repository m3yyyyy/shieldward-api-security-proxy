# Recurring generation-4 production assurance custody reviews

This procedure continues generation-4 custody reviews after the passed Chapter
74 sequence-10 artifact. Every review must bind the exact latest passed
predecessor, derive the next sequence and deadline, revalidate the external
archive controls, and preserve the complete generation-4 inherited lineage.

The scripts record and verify evidence only. They do not schedule reviews,
change retention or object lock, modify archive access, perform restores,
change Kubernetes or traffic, or mutate production workloads.

## Safety boundary

- The first recurring review accepts only the exact passed sequence-10 artifact.
- Every later review accepts only the exact latest passed recurring predecessor.
- Sequence 11 must follow 10, sequence 12 must follow 11, and no sequence may be
  skipped, repeated, or reset.
- Reuse the predecessor's review interval, retention boundary, minimum remaining
  retention, generation 4, renewal sequence 3, and inherited lineage.
- Require available archives, complete inventory, enforced object lock, active
  retention, verified encryption, least-privilege access, and a passed restore.
- Treat late, missing, failed, unknown, stale, wrong-context, substituted, or
  altered evidence as a closed gate.
- Never edit generated JSON. Regenerate it from authoritative observations.

## 1. Verify the synthetic contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-generation-4-custody-recurring-contract.ps1
```

The contract reconstructs the complete prior chain, proves sequences 11 and 12,
and verifies rejection of unsafe results, failed predecessors, stale evidence,
wrong contexts, and tampering.

## 2. Locate the exact predecessor

For sequence 11, use the passed Chapter 74 artifact. For sequence 12 and later,
use the latest passed artifact produced by this procedure.

```powershell
$productionContext = 'REPLACE_WITH_APPROVED_PRODUCTION_CONTEXT'
$previousReviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-4-custody-review' -Filter 'generation-4-custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$baselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-4-custody-baseline' -Filter 'generation-4-custody-baseline-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-next-renewed-retention-renewal-evidence' -Filter 'next-renewed-retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-next-renewed-retention-renewal-plan' -Filter 'next-renewed-retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
```

After the first recurring review, point `$previousReviewFile` at the latest
passed file beneath
`.shieldward/production-assurance-generation-4-custody-recurring`.

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
& .\scripts\new-production-assurance-generation-4-custody-recurring-evidence.ps1 @reviewArguments
```

Use `unknown` whenever a control cannot be proven. Never infer a passing state.

## 4. Validate and gate the review

```powershell
$reviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-4-custody-recurring' -Filter 'generation-4-custody-review-*.json' |
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
& .\scripts\test-production-assurance-generation-4-custody-recurring-evidence.ps1 @validationArguments

$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-generation-4-custody-recurring-gate.ps1 @gateArguments
```

Only a fresh passed gate may become the next predecessor. Chapter 76 may audit
the complete generation-4 chain with the
[generation-4 custody chain audit](production-assurance-generation-4-custody-chain-audit.md)
at an approved governance checkpoint, but an audit must not replace or
reschedule any custody review.

