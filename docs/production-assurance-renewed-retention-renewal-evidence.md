# Renewed production assurance retention-renewal evidence

This procedure records independent evidence that the exact approved Chapter 65
renewed retention-renewal procedure completed in the external archive system.
It proves renewal sequence 2 and the boundary required for baseline generation
3 before a new custody-review baseline may be established.

The scripts are evidence tools only. They do not change archive retention,
object lock, encryption, access, restore state, schedulers, Kubernetes, traffic,
or production workloads.

## Safety boundary

- Begin only with the exact fresh, approved renewed retention-renewal plan.
- Record the external completion time and observed retention boundary from
  independently verified system evidence.
- Require active retention, enforced object lock, complete inventory, verified
  encryption, least-privilege access, and a passed restore test.
- Preserve the exact original and renewed custody lineage carried by the plan.
- Treat failed, unknown, stale, incomplete, altered, or insufficient evidence
  as a closed gate.
- Never edit generated JSON. Regenerate it from authoritative observations.

## 1. Verify the synthetic contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-renewed-retention-renewal-evidence-contract.ps1
```

The contract reconstructs the complete prior chain, verifies the successful
generation-3 and renewal-sequence-2 path, and proves rejection of failed,
unknown, insufficient, stale, wrong-context, and tampered evidence.

## 2. Locate the approved plan

```powershell
$productionContext = 'REPLACE_WITH_APPROVED_PRODUCTION_CONTEXT'
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-retention-renewal-plan' -Filter 'renewed-retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if (-not $planFile) { throw 'No renewed retention-renewal plan was found.' }
```

Confirm that the plan is approved and that its required procedure, archive
reference, generation, sequence, retention date, and production context match
the independently authorized change.

## 3. Record independent execution evidence

Replace every placeholder with an authoritative external reference. The
observed retention date must be at least the approved boundary and cover the
next review plus the plan's required margin.

```powershell
$evidenceArguments = @{
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
  ExecutionCompletedAtUtc = [DateTimeOffset]'REPLACE_WITH_COMPLETION_TIME_UTC'
  ObservedRetentionUntilUtc = [DateTimeOffset]'REPLACE_WITH_OBSERVED_RETENTION_UTC'
  ExternalChangeStatus = 'completed'
  RetentionPolicyStatus = 'active'
  ObjectLockStatus = 'enforced'
  ArchiveInventoryStatus = 'complete'
  EncryptionStatus = 'verified'
  AccessControlStatus = 'least-privilege'
  RestoreVerificationStatus = 'passed'
  ExternalChangeReference = 'REPLACE_WITH_CHANGE_RESULT_REFERENCE'
  RetentionPolicyReference = 'REPLACE_WITH_RETENTION_REFERENCE'
  ObjectLockReference = 'REPLACE_WITH_OBJECT_LOCK_REFERENCE'
  ArchiveInventoryReference = 'REPLACE_WITH_INVENTORY_REFERENCE'
  EncryptionReference = 'REPLACE_WITH_ENCRYPTION_REFERENCE'
  AccessReviewReference = 'REPLACE_WITH_ACCESS_REVIEW_REFERENCE'
  RestoreTestReference = 'REPLACE_WITH_RESTORE_TEST_REFERENCE'
  ExecutedBy = 'REPLACE_WITH_EXTERNAL_OPERATOR'
  VerifiedBy = 'REPLACE_WITH_INDEPENDENT_VERIFIER'
}
& .\scripts\new-production-assurance-renewed-retention-renewal-evidence.ps1 @evidenceArguments
```

Use `failed` or `unknown` statuses when that is what the evidence shows. Do not
convert missing evidence into a passing value.

## 4. Validate the record

```powershell
$evidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-retention-renewal-evidence' -Filter 'renewed-retention-renewal-evidence-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

$validationArguments = @{
  EvidencePath = $evidenceFile.FullName
  PlanPath = $planFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-retention-renewal-evidence.ps1 @validationArguments
```

Validation recomputes the plan hash, inherited lineage, timing, generation,
renewal sequence, observed boundary, result, required action, and integrity
digest. It is read-only.

## 5. Apply the continuation gate

```powershell
$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-renewed-retention-renewal-evidence-gate.ps1 @gateArguments
```

Only a fresh passed gate may hand off to Chapter 67. Chapter 67 must establish
the next renewed custody-review baseline while preserving every original and
renewed lineage digest. Follow the
[next renewed custody baseline](production-assurance-next-renewed-custody-baseline.md)
procedure. This evidence does not itself create that baseline or complete a
custody review.
