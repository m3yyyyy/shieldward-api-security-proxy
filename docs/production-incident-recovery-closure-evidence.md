# Production recovery incident-closure execution evidence

Use this procedure only after
`docs/production-incident-recovery-closure.md` produces an approved plan and its
read-only gate passes. The approved plan proves intent. It is not evidence that
the authoritative external incident system actually recorded closure.

These scripts collect and validate supplied records. They do not close or
reopen an incident, update a change record, route traffic, mutate workloads, or
discard rollback. The authoritative incident, change, traffic, monitoring, and
audit systems remain the source of truth.

## 1. Preserve the approved closure boundary

Keep production traffic at the proven 100 percent boundary with zero traffic
mutation. Retain rollback to 75 percent and emergency disable-to-zero while an
authorized operator performs the approved closure action in the authoritative
external system.

Capture durable proof of:

1. the exact Chapter 48 closure gate that authorized the action;
2. the external incident record showing `closed`;
3. the closure change record showing `completed`;
4. healthy post-closure monitoring at exactly 100 percent traffic;
5. retained rollback readiness; and
6. complete audit evidence identifying the collector.

Missing, failed, degraded, unknown, stale, inconsistent, or tampered evidence
fails closed. Unknown closure state must be treated as an open incident.

## 2. Test the local evidence contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-evidence-contract.ps1
```

Its final line must be:

```text
Production recovery incident closure execution evidence contract passed.
```

The contract uses only synthetic artifacts beneath `.shieldward`. It rejects a
pending closure plan, traffic outside 100 percent, an open or unknown incident,
a failed closure change, degraded monitoring, missing rollback retention,
incomplete audit evidence, stale evidence, and plan or evidence tampering.

## 3. Select the approved closure plan

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$recoveryClosurePlan = `
  '.shieldward/production-incident-recovery-closure/closure.json'

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-gate.ps1 `
  -PlanPath $recoveryClosurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

The gate must pass before an authorized operator acts externally. Do not edit
the plan, reuse a previous gate output, or represent approval as execution.

## 4. Close the incident in the authoritative system

An authorized operator now performs the exact approved closure action in the
external incident and change systems. Confirm that the incident is recorded as
closed and the separate closure change is completed. Keep traffic unchanged at
100 percent and preserve rollback.

The repository intentionally provides no command that performs this external
action.

## 5. Collect immutable closure evidence

Use the exact UTC closure timestamp and durable, non-placeholder references
from the owning systems.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-closure-evidence.ps1 `
  -ClosurePlanPath $recoveryClosurePlan `
  -ExpectedProductionContext $productionContext `
  -ClosedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent 100 `
  -TrafficEnforcementStatus confirmed `
  -ClosureExecutionStatus completed `
  -IncidentClosureStatus closed `
  -ClosureChangeRecordStatus completed `
  -PostClosureMonitoringStatus healthy `
  -RollbackRetentionStatus retained `
  -AuditEvidenceStatus complete `
  -ClosureGateReference 'REPLACE CLOSURE GATE REFERENCE' `
  -IncidentClosureReference 'REPLACE AUTHORITATIVE INCIDENT CLOSURE REFERENCE' `
  -ClosureChangeRecordReference 'REPLACE COMPLETED CLOSURE CHANGE REFERENCE' `
  -PostClosureMonitoringReference 'REPLACE POST-CLOSURE MONITORING REFERENCE' `
  -TrafficStateReference 'REPLACE TRAFFIC STATE REFERENCE' `
  -RollbackRetentionReference 'REPLACE ROLLBACK RETENTION REFERENCE' `
  -AuditEvidenceReference 'REPLACE AUDIT EVIDENCE REFERENCE' `
  -CollectedBy 'REPLACE INDEPENDENT EVIDENCE COLLECTOR' `
  -MaxClosureAgeMinutes 60 `
  -CheckCluster
```

The collector writes a timestamped artifact beneath
`.shieldward/production-incident-recovery-closure-evidence`. It binds the
approved plan hash and approval digest, incident and change identities,
immutable release, closure timestamp, exact traffic boundary, rollback
contract, external references, derived outcome, and integrity digest.

## 6. Inspect and validate the artifact

```powershell
$recoveryClosureEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-closure-evidence\closure-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $recoveryClosureEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-evidence.ps1 `
  -EvidencePath $recoveryClosureEvidenceFile.FullName `
  -ClosurePlanPath $recoveryClosurePlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, `closure.incidentStatus` is `closed`, the change
record is `completed`, observed traffic is exactly 100, traffic mutation is
zero, rollback retention is `retained`, and audit evidence is `complete`.
Never edit the generated JSON.

## 7. Apply the freshness-bound execution gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-evidence-gate.ps1 `
  -EvidencePath $recoveryClosureEvidenceFile.FullName `
  -ClosurePlanPath $recoveryClosurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only that current supplied evidence records the authorized
external closure. It does not perform closure, guarantee future health,
authorize a traffic change, or allow rollback evidence to be discarded.

## 8. Follow the recorded outcome

- Passed evidence may begin post-incident assurance and retrospective work.
- Failed evidence treats the incident as open and escalates through the
  authoritative incident process.
- Unknown evidence treats the incident as open while authoritative closure
  evidence is collected.

Attach the immutable artifact and gate output to the incident and closure
change records. Continue production assurance and retain rollback evidence
according to organizational retention policy.

For passed closure evidence, continue with
`docs/production-post-incident-assurance.md`. That separate freshness-bound
gate proves the later health window, error-budget and security review,
root-cause analysis, tracked corrective actions, completed retrospective, and
retained rollback. Closure alone does not prove those post-incident outcomes.
