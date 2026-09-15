# Recurring production assurance continuity evidence

Use this runbook for review sequence 2 and every later scheduled production
assurance review. Chapter 52 proves the first scheduled review after assurance
resumption. This chapter turns that boundary into a tamper-evident chain: every
new review binds the exact previous passed artifact, derives the next sequence
and expected deadline, and preserves the production and rollback boundary.

The repository intentionally provides no command that schedules a review,
changes traffic, edits an incident, or removes rollback. External operations
systems remain authoritative. These scripts only collect, validate, and gate
the evidence supplied by accountable operators.

## 1. Preserve the recurring boundary

Every recurring review must satisfy all of these conditions:

- the exact previous passed continuity artifact is present and unchanged;
- the review sequence is derived as the previous sequence plus one;
- completion is within five minutes before the previous artifact's deadline
  through the approved completion grace period;
- the external schedule remains active with complete monitoring coverage;
- production traffic remains externally enforced at exactly 100 percent;
- health, error-budget, alert, functional, dependency, capacity, operations,
  and security evidence passes;
- image, policy, configuration, identity, certificate, and routing drift is clear;
- rollback to 75 percent and emergency disable-to-zero remain retained; and
- every external reference identifies current authoritative evidence.

Sequence numbers and deadlines are derived values. An operator cannot skip a
sequence, reset the clock, or use a failed review as the next chain boundary.
A scheduler record alone does not prove execution.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-recurring-contract.ps1
```

Its final line must be:

```text
Recurring production assurance continuity evidence contract passed.
```

The test uses only ignored `.shieldward` data. It proves sequences 2 and 3,
then checks late, missed, unknown, drifted, missing-rollback, mismatched-traffic,
stale, failed-predecessor, and tampered cases without contacting production.

## 3. Select the exact previous passed review

For sequence 2, use the passed Chapter 52 artifact. For every later sequence,
use the immediately preceding recurring artifact.

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$previousContinuityEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-recurring' `
  -Filter 'review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $previousContinuityEvidenceFile) {
  $previousContinuityEvidenceFile = Get-ChildItem -LiteralPath `
    '.\.shieldward\production-assurance-continuity' `
    -Filter 'continuity-*.json' |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
}

if ($null -eq $previousContinuityEvidenceFile) {
  throw 'No passed production assurance continuity evidence was found.'
}

Get-Content -LiteralPath $previousContinuityEvidenceFile.FullName
```

Never edit generated JSON. The collector binds the previous file by relative
path, SHA-256 hash, integrity digest, evidence type, and review sequence.

## 4. Gather authoritative references

```powershell
$previousContinuityGateReference = 'REPLACE_WITH_PREVIOUS_GREEN_GATE_RUN'
$scheduledReviewReference = 'REPLACE_WITH_CURRENT_SCHEDULED_REVIEW_RUN'
$trafficStateReference = 'REPLACE_WITH_100_PERCENT_TRAFFIC_PROOF'
$monitoringEvidenceReference = 'REPLACE_WITH_COMPLETE_MONITORING_PROOF'
$driftEvidenceReference = 'REPLACE_WITH_CURRENT_DRIFT_SCAN'
$rollbackRetentionReference = 'REPLACE_WITH_RETAINED_ROLLBACK_PROOF'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
```

Use immutable identifiers or URLs without credentials, tokens, secret query
parameters, placeholders, or control characters.

## 5. Record the completed recurring review

Use the actual completion timestamp from the authoritative review. Do not copy
the expected deadline when the completion record is missing.

```powershell
$reviewCompletedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-recurring-evidence.ps1 `
  -PreviousContinuityEvidencePath $previousContinuityEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ReviewCompletedAtUtc $reviewCompletedAtUtc `
  -CompletionGraceMinutes 15 `
  -ObservedTrafficPercent 100 `
  -ReviewExecutionStatus completed `
  -TrafficEnforcementStatus confirmed `
  -AssuranceScheduleStatus active `
  -MonitoringCoverageStatus complete `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear `
  -ImageDriftStatus clear `
  -PolicyDriftStatus clear `
  -ConfigurationDriftStatus clear `
  -IdentityDriftStatus clear `
  -CertificateStatus healthy `
  -RoutingDriftStatus clear `
  -RollbackRetentionStatus retained `
  -PreviousContinuityGateReference $previousContinuityGateReference `
  -ScheduledReviewReference $scheduledReviewReference `
  -TrafficStateReference $trafficStateReference `
  -MonitoringEvidenceReference $monitoringEvidenceReference `
  -DriftEvidenceReference $driftEvidenceReference `
  -RollbackRetentionReference $rollbackRetentionReference `
  -ReviewedBy $reviewedBy `
  -MaxPreviousEvidenceAgeHours 168 `
  -MaxReviewAgeMinutes 60 `
  -CheckCluster
```

The output is an immutable JSON file under
`.shieldward/production-assurance-recurring`. The collector derives the review
sequence, expected deadline, on-time result, interval, and next deadline.

## 6. Inspect and validate the artifact

```powershell
$recurringEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-recurring' `
  -Filter 'review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recurringEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-recurring-evidence.ps1 `
  -EvidencePath $recurringEvidenceFile.FullName `
  -PreviousContinuityEvidencePath $previousContinuityEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm the sequence immediately follows the previous review, `outcome` is
`passed`, the review completed on time, traffic remains exactly 100 with zero
mutation, signals and drift pass, rollback is retained, and
`continuityProven` is true.

## 7. Apply the freshness and next-review gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-recurring-gate.ps1 `
  -EvidencePath $recurringEvidenceFile.FullName `
  -PreviousContinuityEvidencePath $previousContinuityEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded recurring review chain. It does not
schedule the next review, authorize drift, mutate traffic, or allow rollback
evidence to be removed.

## 8. Repeat without resetting the chain

At the next deadline, use the artifact just created as
`PreviousContinuityEvidencePath` and repeat this runbook. Late or missed
reviews require external escalation. Failed or unknown reviews cannot become
the predecessor of a later review; follow their recorded response action and
establish a separately approved recovery or re-acceptance boundary.

## 9. Create governance audit checkpoints

After at least one recurring review passes, use
`docs/production-assurance-chain-audit.md` on the approved governance
schedule. Its read-only checkpoint inventories the retained sequence from 1
through the selected head and rejects gaps, cycles, missing predecessors,
failed access or retention controls, and tampering. The checkpoint does not
replace the recurring review schedule.
