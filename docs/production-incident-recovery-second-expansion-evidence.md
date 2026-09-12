# Production recovery second expansion execution evidence

Use this procedure after an approved plan from
`docs/production-incident-recovery-second-expansion.md` has been executed by the
authoritative external traffic controller. It proves whether the exact
recovery second expansion target was reached while workloads, monitoring,
rollback, and incident/change records remained valid.

The repository scripts collect and validate supplied evidence references.
They never route traffic, mutate workloads, approve another expansion, or
close the incident. An approved plan proves intent; only current execution
evidence proves the recorded target.

## 1. Preserve external execution evidence

Before collecting the artifact, preserve all of the following in the owning
systems:

1. the approved second expansion plan, approval digest, and final gate output;
2. the exact UTC execution event and controller audit record;
3. the controller's observed traffic percentage;
4. workload, error-budget, alert, functional, dependency, operational, and
   capacity verification;
5. security, drift, and certificate state;
6. readiness to restore the previous healthy recovery boundary or disable to zero;
7. the updated incident record; and
8. the completed second-expansion recovery change record.

Do not infer success from an accepted command, desired state, or approved
plan. Missing, failed, degraded, exhausted, firing, unknown, mismatched, stale,
or tampered evidence fails closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-evidence-contract.ps1
```

Its final line must be:

```text
Production recovery second expansion execution evidence contract passed.
```

The test creates only synthetic artifacts beneath `.shieldward`. It proves
the approved 50-to-75-percent execution path and rejects an unapproved plan,
target mismatch, failed workloads, unknown enforcement, exhausted error
budget, unavailable rollback, and tampering.

## 3. Confirm the approved second expansion

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$recoverySecondExpansionPlan = `
  '.shieldward/production-incident-recovery-second-expansion/expansion.json'
$secondExpansionPlan = Get-Content -Raw -LiteralPath $recoverySecondExpansionPlan |
  ConvertFrom-Json

$secondExpansionPlan.state
$secondExpansionPlan.incidentId
$secondExpansionPlan.expansionChangeId
$secondExpansionPlan.progressiveChangeId
$secondExpansionPlan.secondExpansionChangeId
$secondExpansionPlan.traffic.currentPercent
$secondExpansionPlan.traffic.targetPercent
$secondExpansionPlan.rollback.targetPercent
$secondExpansionPlan.approval.approvalDigest
```

The state must be `approved`. The observed traffic must later equal
`traffic.targetPercent` exactly, while rollback remains
`traffic.currentPercent` and emergency disable remains zero.

## 4. Collect current second-expansion execution evidence

Use the actual execution timestamp and durable references from the external
systems:

```powershell
$executedAtUtc = [DateTimeOffset]'REPLACE_WITH_EXECUTION_UTC_TIMESTAMP'
$observedTrafficPercent = [int]$secondExpansionPlan.traffic.targetPercent

pwsh -NoProfile -File .\scripts\new-production-incident-recovery-second-expansion-evidence.ps1 `
  -SecondExpansionPlanPath $recoverySecondExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -ExecutedAtUtc $executedAtUtc `
  -ObservedTrafficPercent $observedTrafficPercent `
  -TrafficEnforcementStatus confirmed `
  -WorkloadVerificationStatus confirmed `
  -SecondExpansionExecutionStatus completed `
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
  -SecondExpansionChangeRecordStatus updated `
  -TrafficStateReference 'REPLACE TRAFFIC AUDIT REFERENCE' `
  -WorkloadEvidenceReference 'REPLACE WORKLOAD EVIDENCE REFERENCE' `
  -SecondExpansionExecutionReference 'REPLACE SECOND EXPANSION EXECUTION REFERENCE' `
  -SecondExpansionGateReference 'REPLACE PRE-EXECUTION GATE REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -SecondExpansionChangeRecordReference 'REPLACE SECOND EXPANSION CHANGE REFERENCE' `
  -CollectedBy 'REPLACE RECOVERY SECOND EXPANSION EVIDENCE REVIEWER' `
  -MaxExecutionAgeMinutes 60 `
  -CheckCluster
```

The output is a timestamped file beneath
`.shieldward/production-incident-recovery-second-expansion-evidence`. The collector
binds the approved plan hash, integrity and approval digests, exact traffic
target, execution window, all verification states, rollback boundary, and
external references.

Record failed or unknown states honestly. The collector preserves that result
and the gate blocks it. Never edit timestamps or percentages to make execution
appear successful.

## 5. Inspect and validate

```powershell
$recoverySecondExpansionEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-second-expansion-evidence\second-expansion-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recoverySecondExpansionEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-evidence.ps1 `
  -EvidencePath $recoverySecondExpansionEvidenceFile.FullName `
  -SecondExpansionPlanPath $recoverySecondExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

The validator rechecks the complete approved plan chain, plan hash and approval
digest, exact execution window and target, verification states, rollback,
external references, derived decision, and evidence integrity digest.

## 6. Apply the freshness-bound execution gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-evidence-gate.ps1 `
  -EvidencePath $recoverySecondExpansionEvidenceFile.FullName `
  -SecondExpansionPlanPath $recoverySecondExpansionPlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The gate requires exact externally enforced traffic, completed execution,
healthy workloads and signals, ready rollback, updated incident/change
records, a passed outcome, and current evidence.

## 7. Follow the recorded next action

- Passed evidence holds the exact expanded percentage for a new bounded
  observation period. It does not authorize another increase.
- Failed evidence restores the previous healthy boundary through the authoritative
  controller and escalates.
- Unknown evidence holds the safest confirmed boundary while missing evidence
  is collected. Unknown enforcement must never be represented as successful.

Attach the immutable artifact and gate output to the incident and recovery
second expansion change records.

## 8. Keep execution separate from closure

A green execution gate proves only the recorded target at the recorded time.
Another expansion requires a separate observation, plan, approval, and
execution-evidence cycle. Incident closure requires its own sustained-health
review and retained audit evidence.

For passed evidence, begin another bounded observation before proposing any
later recovery step. Preserve this artifact as the immutable prior boundary;
do not treat it as approval for a further increase.

Any later recovery increase requires a new observation, a new bounded plan,
and separate exact approval. Preserve this artifact as evidence only.
