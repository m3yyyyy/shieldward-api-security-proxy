# Production recovery final expansion execution evidence

Use this procedure after an approved plan from
`docs/production-incident-recovery-final-expansion.md` has been executed by the
authoritative external traffic controller. It proves whether the exact
recovery final expansion target was reached while workloads, monitoring,
rollback, and incident/change records remained valid.

The repository scripts collect and validate supplied evidence references.
They never route traffic, mutate workloads, approve another expansion, or
close the incident. An approved plan proves intent; only current execution
evidence proves the recorded target.

## 1. Preserve external execution evidence

Before collecting the artifact, preserve all of the following in the owning
systems:

1. the approved final expansion plan, approval digest, and final gate output;
2. the exact UTC execution event and controller audit record;
3. the controller's observed traffic percentage;
4. workload, error-budget, alert, functional, dependency, operational, and
   capacity verification;
5. security, drift, and certificate state;
6. readiness to restore the previous healthy recovery boundary or disable to zero;
7. the updated incident record; and
8. the completed final-expansion recovery change record.

Do not infer success from an accepted command, desired state, or approved
plan. Missing, failed, degraded, exhausted, firing, unknown, mismatched, stale,
or tampered evidence fails closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-evidence-contract.ps1
```

Its final line must be:

```text
Production recovery final expansion execution evidence contract passed.
```

The test creates only synthetic artifacts beneath `.shieldward`. It proves
the approved 75-to-100-percent execution path and rejects an unapproved plan,
target mismatch, failed workloads, unknown enforcement, exhausted error
budget, unavailable rollback, and tampering.

## 3. Confirm the approved final expansion

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$recoveryFinalExpansionPlan = `
  '.shieldward/production-incident-recovery-final-expansion/expansion.json'
$finalExpansionPlan = Get-Content -Raw -LiteralPath $recoveryFinalExpansionPlan |
  ConvertFrom-Json

$finalExpansionPlan.state
$finalExpansionPlan.incidentId
$finalExpansionPlan.expansionChangeId
$finalExpansionPlan.progressiveChangeId
$finalExpansionPlan.secondExpansionChangeId
$finalExpansionPlan.finalExpansionChangeId
$finalExpansionPlan.traffic.currentPercent
$finalExpansionPlan.traffic.targetPercent
$finalExpansionPlan.rollback.targetPercent
$finalExpansionPlan.approval.approvalDigest
```

The state must be `approved`. The observed traffic must later equal
`traffic.targetPercent` exactly, while rollback remains
`traffic.currentPercent` and emergency disable remains zero.

## 4. Collect current final-expansion execution evidence

Use the actual execution timestamp and durable references from the external
systems:

```powershell
$executedAtUtc = [DateTimeOffset]'REPLACE_WITH_EXECUTION_UTC_TIMESTAMP'
$observedTrafficPercent = 100

pwsh -NoProfile -File .\scripts\new-production-incident-recovery-final-expansion-evidence.ps1 `
  -FinalExpansionPlanPath $recoveryFinalExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -ExecutedAtUtc $executedAtUtc `
  -ObservedTrafficPercent $observedTrafficPercent `
  -TrafficEnforcementStatus confirmed `
  -WorkloadVerificationStatus confirmed `
  -FinalExpansionExecutionStatus completed `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear `
  -DriftStatus clear `
  -CertificateStatus healthy `
  -RollbackReadinessStatus ready `
  -IncidentRecordStatus updated `
  -FinalExpansionChangeRecordStatus updated `
  -TrafficStateReference 'REPLACE TRAFFIC AUDIT REFERENCE' `
  -WorkloadEvidenceReference 'REPLACE WORKLOAD EVIDENCE REFERENCE' `
  -FinalExpansionExecutionReference 'REPLACE FINAL EXPANSION EXECUTION REFERENCE' `
  -FinalExpansionGateReference 'REPLACE PRE-EXECUTION GATE REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -FinalExpansionChangeRecordReference 'REPLACE FINAL EXPANSION CHANGE REFERENCE' `
  -CollectedBy 'REPLACE RECOVERY FINAL EXPANSION EVIDENCE REVIEWER' `
  -MaxExecutionAgeMinutes 60 `
  -CheckCluster
```

The output is a timestamped file beneath
`.shieldward/production-incident-recovery-final-expansion-evidence`. The collector
binds the approved plan hash, integrity and approval digests, exact traffic
target, execution window, all verification states, rollback boundary, and
external references.

Record failed or unknown states honestly. The collector preserves that result
and the gate blocks it. Never edit timestamps or percentages to make execution
appear successful.

## 5. Inspect and validate

```powershell
$recoveryFinalExpansionEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-final-expansion-evidence\final-expansion-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recoveryFinalExpansionEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-evidence.ps1 `
  -EvidencePath $recoveryFinalExpansionEvidenceFile.FullName `
  -FinalExpansionPlanPath $recoveryFinalExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

The validator rechecks the complete approved plan chain, plan hash and approval
digest, exact execution window and target, verification states, rollback,
external references, derived decision, and evidence integrity digest.

## 6. Apply the freshness-bound execution gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-evidence-gate.ps1 `
  -EvidencePath $recoveryFinalExpansionEvidenceFile.FullName `
  -FinalExpansionPlanPath $recoveryFinalExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The gate requires exact externally enforced traffic, completed execution,
healthy workloads and signals, ready rollback, updated incident/change
records, a passed outcome, and current evidence.

## 7. Follow the recorded next action

- Passed evidence holds the exact 100 percent boundary for a new bounded
  observation period. It does not authorize incident closure.
- Failed evidence restores the previous healthy boundary through the authoritative
  controller and escalates.
- Unknown evidence holds the safest confirmed boundary while missing evidence
  is collected. Unknown enforcement must never be represented as successful.

Passed evidence permits an independent production re-acceptance and incident-
closure review to begin. It does not itself close the incident, satisfy
acceptance, authorize closure, or allow the rollback boundary to be discarded.

Attach the immutable artifact and gate output to the incident and recovery
final expansion change records.

## 8. Keep execution separate from closure

A green execution gate proves only the recorded 100 percent target at the
recorded time. Incident closure requires independent production re-acceptance,
a sustained-health review, completed external incident/change approvals, and
retained audit evidence.

For passed evidence, follow
`docs/production-incident-recovery-closure.md`. That gate binds the sustained
100 percent observation, independent production re-acceptance, separate closure
change, and exact approval without changing traffic or closing the incident.
Keep rollback to 75 percent or emergency disable-to-zero available until the
authoritative incident system records closure.

Preserve this artifact as execution evidence only; never represent it as an
automatic incident-closure decision.
