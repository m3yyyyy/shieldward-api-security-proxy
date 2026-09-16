# Production assurance renewed custody-review baseline

Use this runbook only after Chapter 60 has produced fresh, passed
retention-renewal execution evidence. Chapter 61 creates a separate
tamper-evident bridge from the original custody and review chain to the renewed
retention boundary.

The baseline does not rewrite the original custody record, replace the prior
review chain, reset its sequence, schedule a review, or mutate an archive. It
preserves the old review head and derives the next sequence and deadline from
the exact passed renewal evidence.

## 1. Preserve the lineage boundary

A valid renewed baseline requires all of these conditions:

- the exact Chapter 60 evidence remains present, passed, fresh, and unchanged;
- the exact approved Chapter 59 plan remains valid through that evidence;
- baseline establishment follows renewal execution and evidence collection;
- the baseline is created before the inherited next-review deadline;
- the original custody path, checksum, integrity digest, and chain digest are
  unchanged;
- the prior custody-review chain digest and head sequence are unchanged;
- the renewed retention date is strictly later than the prior date;
- the next review sequence is exactly the prior head plus one; and
- the renewed lineage digest binds the old custody identity, old review-chain
  head, exact renewal evidence, new retention boundary, and next review.

Passing renewal evidence is not permission to rewrite history. The renewed
baseline starts generation 2 while preserving generation 1 as immutable
lineage.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-renewed-custody-baseline-contract.ps1
~~~

Its final line must be:

~~~text
Production assurance renewed custody-review baseline contract passed.
~~~

The test uses only ignored .shieldward data. It covers passed renewal
evidence, a failed renewal, early establishment, placeholder references,
incorrect context, stale and overdue gates, and tampering with both the
baseline and its exact renewal evidence.

## 3. Select the exact passed renewal evidence

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-plan' -Filter 'retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-evidence' -Filter 'retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $renewalPlanFile -or $null -eq $renewalEvidenceFile) {
  throw 'The approved plan and passed retention-renewal evidence are required.'
}

$renewalGateArguments = @{
  EvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  MaxEvidenceAgeMinutes = 60
}
& .\scripts\test-production-assurance-retention-renewal-evidence-gate.ps1 @renewalGateArguments
~~~

Never edit generated JSON. The new baseline binds this exact evidence by path,
SHA-256, integrity digest, collection time, and execution time.

## 4. Record the baseline authority

~~~powershell
$baselineEstablishedAtUtc = [DateTimeOffset]::UtcNow
$baselineReference = 'REPLACE_WITH_IMMUTABLE_BASELINE_RECORD'
$establishedBy = 'REPLACE_WITH_CUSTODY_OWNER'
$verifiedBy = 'REPLACE_WITH_INDEPENDENT_VERIFIER'
~~~

References must be non-secret authoritative identifiers or URLs without
credentials, tokens, placeholder text, query secrets, or control characters.

## 5. Create the renewed baseline

~~~powershell
$newBaselineArguments = @{
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  BaselineEstablishedAtUtc = $baselineEstablishedAtUtc
  BaselineReference = $baselineReference
  EstablishedBy = $establishedBy
  VerifiedBy = $verifiedBy
  MaxRenewalEvidenceAgeMinutes = 60
  MaxBaselineEstablishmentAgeMinutes = 60
}
& .\scripts\new-production-assurance-renewed-custody-baseline.ps1 @newBaselineArguments
~~~

The immutable JSON output is written beneath
.shieldward/production-assurance-renewed-custody-baseline.

## 6. Inspect and validate the baseline

~~~powershell
$renewedBaselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-baseline' -Filter 'renewed-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

Get-Content -LiteralPath $renewedBaselineFile.FullName

$baselineValidationArguments = @{
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-custody-baseline.ps1 @baselineValidationArguments
~~~

Confirm outcome is passed, generation is 2, renewal sequence is 1, the old
head remains unchanged, the next sequence is exactly old head plus one, all
three preservation decisions are true, and the action is
resume-scheduled-custody-reviews.

## 7. Apply the resumption gate

~~~powershell
$baselineGateArguments = $baselineValidationArguments.Clone()
$baselineGateArguments.MaxBaselineAgeMinutes = 60
& .\scripts\test-production-assurance-renewed-custody-baseline-gate.ps1 @baselineGateArguments
~~~

The gate fails closed if the bridge is stale, future-dated, overdue for the
inherited next review, outside renewed retention, or changed. A green gate
authorizes only resuming the existing review process.

## 8. Resume without resetting history

Preserve the baseline, Chapter 60 evidence, Chapter 59 plan, original custody
record, and every prior review. Use the recorded nextReviewSequence and
nextReviewDueAtUtc for the next renewed custody review. Do not renumber prior
reviews, replace the original custody checksum, or treat baseline creation as a
completed review.

At the inherited deadline, follow the
[renewed custody-review evidence](production-assurance-renewed-custody-review.md)
procedure. It derives the exact sequence and deadline from this baseline and
records current external archive-control observations.

No review was scheduled and no archive, retention, cluster, traffic, or
rollback change was made by Chapter 61.
