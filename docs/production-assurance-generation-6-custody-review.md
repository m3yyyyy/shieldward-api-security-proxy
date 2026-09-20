# Generation-6 production assurance custody review

This procedure records the first custody review after the generation-6 baseline.
It requires the exact Chapter 85 baseline, completes review sequence 16 at the
inherited deadline, revalidates every external archive control, and preserves
the complete original and renewed custody lineage.

The scripts record and verify evidence only. They do not schedule reviews,
change retention or object lock, modify archive access, perform restores,
change Kubernetes or traffic, or mutate production workloads.

## Safety boundary

- Begin only with the exact fresh, passed generation-6 Chapter 85 baseline.
- Complete review sequence 16 within the inherited deadline and grace period.
- Require available archives, complete inventory, enforced object lock, active
  retention, verified encryption, least-privilege access, and a passed restore.
- Keep the next review inside the observed retention boundary with the required
  remaining-retention margin.
- Preserve the generation-5 baseline, all five renewals, original custody
  identity, and the complete inherited review-chain lineage.
- Treat late, missing, failed, unknown, stale, wrong-context, or altered evidence
  as a closed gate. Unknown states fail closed.
- Never edit generated JSON. Regenerate it from authoritative observations.

## 1. Verify the synthetic contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-generation-6-custody-review-contract.ps1
```

The contract reconstructs the complete prior chain, proves the healthy
generation-6 sequence-16 result, and verifies rejection of unsafe review states.

## 2. Locate the generation-6 baseline

```powershell
$productionContext = 'REPLACE_WITH_APPROVED_PRODUCTION_CONTEXT'
$baselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-baseline' -Filter 'generation-6-custody-baseline-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-evidence' -Filter 'generation-5-retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-plan' -Filter 'generation-5-retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if (-not $baselineFile -or -not $renewalEvidenceFile -or -not $planFile) {
  throw 'The generation-6 baseline or its renewal evidence is missing.'
}
```

The baseline must show generation `6`, renewal sequence `5`, previous review
head `15`, next sequence `16`, and the approved production context.

## 3. Record sequence-16 review evidence

Replace every placeholder with an authoritative external reference. Use
`unknown` rather than assuming a passing state when evidence is unavailable.

```powershell
$reviewArguments = @{
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
  ReviewCompletedAtUtc = [DateTimeOffset]::UtcNow
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
  ScheduledReviewReference = 'REPLACE_WITH_REVIEW_REFERENCE'
  ArchiveInventoryReference = 'REPLACE_WITH_INVENTORY_REFERENCE'
  ObjectLockReference = 'REPLACE_WITH_OBJECT_LOCK_REFERENCE'
  RetentionPolicyReference = 'REPLACE_WITH_RETENTION_REFERENCE'
  EncryptionReference = 'REPLACE_WITH_ENCRYPTION_REFERENCE'
  AccessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW_REFERENCE'
  RestoreTestReference = 'REPLACE_WITH_RESTORE_TEST_REFERENCE'
  ReviewedBy = 'REPLACE_WITH_INDEPENDENT_REVIEWER'
}
& .\scripts\new-production-assurance-generation-6-custody-review-evidence.ps1 @reviewArguments
```

## 4. Validate the evidence

```powershell
$reviewFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-review' -Filter 'generation-6-custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

$validationArguments = @{
  EvidencePath = $reviewFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-generation-6-custody-review-evidence.ps1 @validationArguments
```

Validation recomputes the baseline hash, inherited lineage, sequence and timing,
retention calculations, outcome, next action, review-link digest, and integrity
digest. It is read-only.

## 5. Apply the continuation gate

```powershell
$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-generation-6-custody-review-gate.ps1 @gateArguments
```

Only fresh passed evidence may continue. Chapter 87 must use this exact passed
sequence-16 artifact as the predecessor for sequence 17; it must not reset the
generation, renewal sequence, lineage, deadline, or retention boundary.
