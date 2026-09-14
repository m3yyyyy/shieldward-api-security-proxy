# Scheduled production assurance continuity evidence

Use this runbook for the first scheduled review after the continuous assurance
resumption gate passes. Chapter 51 proves monitoring was re-established. This
chapter proves the recorded next review actually completed within its deadline,
with healthy signals, no drift, exact full traffic, and retained rollback.

The repository intentionally provides no command that schedules a review,
changes traffic, edits an incident, or removes rollback. External operations
systems remain authoritative. These scripts only collect, validate, and gate
the evidence supplied by accountable operators.

## 1. Preserve the scheduled boundary

The first review must satisfy all of these conditions:

- it uses the exact passed Chapter 51 resumption artifact;
- its completion timestamp is within five minutes before the recorded due time
  through the approved completion grace period;
- the review execution is recorded as completed;
- the external schedule remains active with complete monitoring coverage;
- production traffic remains externally enforced at exactly 100 percent;
- health, error-budget, alert, functional, dependency, capacity, operations,
  and security evidence passes;
- image, policy, configuration, identity, certificate, and routing drift is clear;
- rollback to 75 percent and emergency disable-to-zero remain retained; and
- every external reference identifies current authoritative evidence.

A running scheduler does not prove that a review completed. Late, missed,
unknown, stale, unhealthy, drifted, or tampered evidence fails closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-continuity-contract.ps1
```

Its final line must be:

```text
Scheduled production assurance continuity evidence contract passed.
```

The test uses only ignored `.shieldward` data. It verifies passed, late,
missed, unknown, drift, missing-rollback, mismatched-traffic, stale, and
tampered cases without contacting production.

## 3. Select the passed upstream artifacts

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$closurePlan = '.shieldward/production-incident-recovery-closure/closure.json'
$closureEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-incident-recovery-closure-evidence' `
  -Filter 'closure-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$postIncidentEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-post-incident-assurance' `
  -Filter 'assurance-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$resumptionEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-resumption' `
  -Filter 'resumption-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $closureEvidenceFile -or
    $null -eq $postIncidentEvidenceFile -or
    $null -eq $resumptionEvidenceFile) {
  throw 'Required closure, post-incident, or resumption evidence was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-resumption-gate.ps1 `
  -EvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The continuity artifact binds the exact resumption artifact by relative path,
SHA-256 hash, and integrity digest. Never edit generated JSON.

## 4. Gather authoritative references

```powershell
$resumptionGateReference = 'REPLACE_WITH_RESUMPTION_GATE_RUN'
$scheduledReviewReference = 'REPLACE_WITH_SCHEDULED_REVIEW_RUN'
$trafficStateReference = 'REPLACE_WITH_100_PERCENT_TRAFFIC_PROOF'
$monitoringEvidenceReference = 'REPLACE_WITH_COMPLETE_MONITORING_PROOF'
$driftEvidenceReference = 'REPLACE_WITH_CURRENT_DRIFT_SCAN'
$rollbackRetentionReference = 'REPLACE_WITH_RETAINED_ROLLBACK_PROOF'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
```

Use immutable external identifiers or URLs without credentials, tokens, secret
query parameters, placeholders, or control characters.

## 5. Record the first scheduled review

Use the real completion timestamp from the authoritative review run. Do not
substitute the expected deadline for a missing completion record.

```powershell
$reviewCompletedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-continuity-evidence.ps1 `
  -ResumptionEvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -ReviewCompletedAtUtc $reviewCompletedAtUtc `
  -ReviewSequence 1 `
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
  -ResumptionGateReference $resumptionGateReference `
  -ScheduledReviewReference $scheduledReviewReference `
  -TrafficStateReference $trafficStateReference `
  -MonitoringEvidenceReference $monitoringEvidenceReference `
  -DriftEvidenceReference $driftEvidenceReference `
  -RollbackRetentionReference $rollbackRetentionReference `
  -ReviewedBy $reviewedBy `
  -MaxResumptionEvidenceAgeHours 168 `
  -MaxReviewAgeMinutes 60 `
  -CheckCluster
```

The output is a timestamped immutable JSON file under
`.shieldward/production-assurance-continuity`. The collector derives the due
time from Chapter 51 and calculates `review.onTime`; the caller cannot declare
that value directly.

## 6. Inspect and validate the artifact

```powershell
$continuityEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-continuity' `
  -Filter 'continuity-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $continuityEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-continuity-evidence.ps1 `
  -EvidencePath $continuityEvidenceFile.FullName `
  -ResumptionEvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, review sequence 1 completed on time, monitoring
continues, traffic is exactly 100 with zero mutation, signals and drift pass,
rollback is retained, and `continuityProven` is true.

## 7. Apply the freshness and next-review gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-continuity-gate.ps1 `
  -EvidencePath $continuityEvidenceFile.FullName `
  -ResumptionEvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded first-review evidence. It does not schedule reviews,
guarantee later execution, authorize drift, mutate traffic, or allow rollback
evidence to be removed.

## 8. Continue ordinary assurance

After a passed gate, use `docs/production-assurance.md` for every later
scheduled snapshot. Late or missed reviews require external escalation;
unhealthy or drifted evidence follows the response action recorded by the
artifact. Attach the continuity artifact and gate output to the incident and
ongoing operational record.
