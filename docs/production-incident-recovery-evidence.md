# Production incident recovery execution evidence

Use this procedure after an approved plan from
`docs/production-incident-recovery.md` has been executed by the authoritative
external traffic controller. It proves whether the exact recovery target was
reached while workloads, monitoring, rollback readiness, and incident/change
records remained valid.

The repository scripts collect and validate supplied evidence references. They
never route traffic, mutate workloads, close an incident, or authorize a later
expansion. Approval proves intent; only current execution evidence proves the
recorded recovery target.

## 1. Preserve external execution evidence

Before collecting the artifact, preserve all of the following in the owning
systems:

1. the approved recovery plan, approval digest, and preserved final gate output;
2. the exact UTC execution event;
3. the external controller's observed traffic percentage;
4. workload and functional verification;
5. dependency, operational, capacity, security, drift, and certificate state;
6. readiness to restore the contained or emergency boundary;
7. the updated incident record; and
8. the completed recovery change record.

Do not infer success from an accepted command, an approved plan, or desired
state. Missing, failed, degraded, unknown, mismatched, stale, or tampered
evidence fails closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-evidence-contract.ps1
```

Its final line must be:

```text
Production incident recovery execution evidence contract passed.
```

The test creates only synthetic artifacts under `.shieldward`. It proves the
0% to canary, 75% to 100%, and 100% hold-resumption execution paths. It also
proves that pending or blocked plans, target mismatch, failed workloads,
unknown enforcement, unavailable rollback, and tampering are rejected.

## 3. Confirm the approved target

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$recoveryPlanPath = '.shieldward/production-incident-recovery/recovery.json'
$recoveryPlan = Get-Content -Raw -LiteralPath $recoveryPlanPath |
  ConvertFrom-Json

$recoveryPlan.state
$recoveryPlan.incidentId
$recoveryPlan.recoveryChangeId
$recoveryPlan.traffic.currentPercent
$recoveryPlan.traffic.targetPercent
$recoveryPlan.rollback.targetPercent
$recoveryPlan.approval.approvalDigest
```

The state must be `approved`. The observed traffic must later equal
`traffic.targetPercent` exactly. A zero-traffic recovery remains a 1-10%
canary; it is not full-traffic recovery.

## 4. Collect current recovery execution evidence

Use the actual timestamp and durable references from the external systems:

```powershell
$executedAtUtc = [DateTimeOffset]'REPLACE_WITH_EXECUTION_UTC_TIMESTAMP'
$observedTrafficPercent = [int]$recoveryPlan.traffic.targetPercent

pwsh -NoProfile -File .\scripts\new-production-incident-recovery-evidence.ps1 `
  -RecoveryPlanPath $recoveryPlanPath `
  -ExpectedProductionContext $productionContext `
  -ExecutedAtUtc $executedAtUtc `
  -ObservedTrafficPercent $observedTrafficPercent `
  -TrafficEnforcementStatus confirmed `
  -WorkloadVerificationStatus confirmed `
  -RecoveryExecutionStatus completed `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear `
  -DriftStatus clear `
  -CertificateStatus healthy `
  -RollbackReadinessStatus ready `
  -IncidentRecordStatus updated `
  -RecoveryChangeRecordStatus updated `
  -TrafficStateReference 'REPLACE TRAFFIC AUDIT REFERENCE' `
  -WorkloadEvidenceReference 'REPLACE WORKLOAD EVIDENCE REFERENCE' `
  -RecoveryExecutionReference 'REPLACE RECOVERY EXECUTION REFERENCE' `
  -RecoveryGateReference 'REPLACE PRE-EXECUTION GATE REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -RecoveryChangeRecordReference 'REPLACE RECOVERY CHANGE REFERENCE' `
  -CollectedBy 'REPLACE RECOVERY EVIDENCE REVIEWER' `
  -MaxExecutionAgeMinutes 60 `
  -CheckCluster
```

The output is a timestamped file beneath
`.shieldward/production-incident-recovery-evidence`. The collector binds the
approved plan hash, integrity and approval digests, execution window, exact
traffic target, all verification states, rollback boundary, and external
references.

Record failed or unknown states honestly. The collector preserves that result
and the gate blocks it. Never edit timestamps or percentages to make execution
appear successful.

## 5. Inspect and validate

```powershell
$recoveryEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-evidence\recovery-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recoveryEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-evidence.ps1 `
  -EvidencePath $recoveryEvidenceFile.FullName `
  -RecoveryPlanPath $recoveryPlanPath `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

The validator rechecks the complete approved recovery chain, exact execution
window and target, verification states, rollback readiness, derived decision,
external references, and integrity digest.

## 6. Apply the freshness-bound execution gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-evidence-gate.ps1 `
  -EvidencePath $recoveryEvidenceFile.FullName `
  -RecoveryPlanPath $recoveryPlanPath `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The gate requires exact externally enforced traffic, completed execution,
healthy workloads and signals, ready rollback, updated incident/change
records, a passed outcome, and current evidence.

## 7. Follow the recorded next action

- A passed 1-10% recovery canary remains at that exact percentage for a bounded
  observation period. It does not authorize expansion.
- A passed 100% recovery resumes continuous production assurance, but it does
  not erase the incident history or replace the closure process.
- Failed or unknown recovery requires immediate external restoration of the
  contained boundary, escalation, and new evidence. Never continue from the
  failed artifact.

Attach the immutable execution artifact and gate output to the incident and
recovery change records.

## 8. Keep execution separate from closure

A green execution gate proves only the recorded target at the recorded time.
Incident closure requires a separate review of sustained health, rollback
availability, follow-up actions, and retained audit evidence. Do not represent
target execution as incident closure.

For a passed 1-10 percent recovery canary, continue with
`docs/production-incident-recovery-expansion.md`. That procedure requires a
complete healthy observation and a new exact approval before any external
increase, capped at 25 percent. A 100 percent recovery instead returns to
continuous production assurance.
