# Generation-6 production assurance custody baseline

This procedure establishes the generation-6 custody-review baseline after the
fifth external retention renewal has been independently proven. It binds the
exact passed Chapter 84 evidence, preserves every original and renewed lineage
digest, and carries the existing review-chain head at sequence 15 forward to the
inherited sequence-16 deadline.

The baseline is a local, tamper-evident handoff record. It does not schedule or
complete a review and does not change archives, retention, object lock, access,
restore state, Kubernetes, traffic, or production workloads.

## Safety boundary

- Accept only the exact fresh, passed Chapter 84 renewal evidence.
- Derive generation 6 from generation 5 and renewal sequence 5 from sequence 4.
- Preserve the prior generation-5 baseline, all five renewal records, the
  original custody identity, and the complete inherited review-chain lineage.
- Preserve review head sequence 15 and derive sequence 16 without resetting it.
- Reuse the inherited next-review deadline and externally observed retention
  boundary; local metadata cannot extend either value.
- Treat failed, unknown, stale, overdue, wrong-context, or altered evidence as
  a closed gate.
- Never edit generated JSON. Regenerate it from authoritative evidence.

## 1. Verify the synthetic contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-generation-6-custody-baseline-contract.ps1
```

The contract reconstructs the complete prior chain and proves the successful
generation-6, renewal-sequence-5, review-sequence-16 path. It also verifies that
failed, unknown, premature, placeholder, stale, overdue, wrong-context, and
tampered records are rejected.

## 2. Locate the passed renewal evidence

```powershell
$productionContext = 'REPLACE_WITH_APPROVED_PRODUCTION_CONTEXT'
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-evidence' -Filter 'generation-5-retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-plan' -Filter 'generation-5-retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if (-not $renewalEvidenceFile -or -not $planFile) {
  throw 'The generation-5 retention evidence or its approved plan is missing.'
}
```

Inspect both records. The evidence must be passed, fresh, and bound to the
exact approved plan and production context.

## 3. Establish the generation-6 baseline

```powershell
$baselineArguments = @{
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
  BaselineEstablishedAtUtc = [DateTimeOffset]::UtcNow
  BaselineReference = 'REPLACE_WITH_BASELINE_RECORD_REFERENCE'
  EstablishedBy = 'REPLACE_WITH_CUSTODY_OWNER'
  VerifiedBy = 'REPLACE_WITH_INDEPENDENT_VERIFIER'
  MaxRenewalEvidenceAgeMinutes = 60
  MaxBaselineEstablishmentAgeMinutes = 60
}
& .\scripts\new-production-assurance-generation-6-custody-baseline.ps1 @baselineArguments
```

The output is written beneath
`.shieldward/production-assurance-generation-6-custody-baseline`. It records
generation 6 and sequence 16 only when those values follow exactly from the
verified inherited chain.

## 4. Validate the baseline

```powershell
$baselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-baseline' -Filter 'generation-6-custody-baseline-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

$validationArguments = @{
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-generation-6-custody-baseline.ps1 @validationArguments
```

Validation recomputes the evidence hash, full inherited lineage, generation,
renewal and review sequences, dates, lineage digest, and baseline integrity
digest. It is read-only.

## 5. Apply the continuation gate

```powershell
$gateArguments = $validationArguments.Clone()
$gateArguments.MaxBaselineAgeMinutes = 60
& .\scripts\test-production-assurance-generation-6-custody-baseline-gate.ps1 @gateArguments
```

A green gate authorizes only continuation of the inherited review process.
Chapter 86 must record the actual sequence-16 custody review at the inherited
deadline and revalidate all external archive controls. Follow the
[generation-6 custody-review procedure](production-assurance-generation-6-custody-review.md).
Chapter 85 neither schedules nor completes that review.
