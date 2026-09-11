# Production recovery canary observation and expansion gate

Use this procedure only after
`docs/production-incident-recovery-evidence.md` proves an externally enforced
1-10 percent recovery canary. It records the completed canary observation and
creates one separately approved recovery expansion capped at 25 percent total
traffic.

The scripts validate supplied evidence and approval records. They never route
traffic, mutate workloads, close the incident, or prove that the approved
expansion was executed. The authoritative traffic, monitoring, incident, and
change systems remain the source of truth.

## 1. Hold and observe the exact recovery canary

Keep traffic at the percentage proven by the recovery execution artifact for
the full approved observation window. Preserve durable external evidence for:

1. stable traffic and workloads at the exact recovery canary;
2. error-budget consumption, alerts, functional checks, dependencies,
   operations, and capacity;
3. security, policy/configuration drift, and certificate health;
4. immediate rollback to the recovery canary and emergency disable-to-zero;
5. the updated incident record; and
6. a separate, approved recovery expansion change record.

Failed, degraded, unknown, missing, pending, stale, incomplete, or tampered
evidence fails closed. A healthy observation does not itself authorize a
traffic increase.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-expansion-contract.ps1
```

Its final line must be:

```text
Production recovery canary observation and expansion planning contract passed.
```

The test uses only synthetic artifacts beneath `.shieldward`. It proves a
bounded 1-to-25-percent plan and rejects full-traffic input, oversized targets,
degraded or unknown signals, a pending external change, an incomplete
observation, invalid approval, and tampering.

## 3. Select the passed recovery execution artifact

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$recoveryEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-evidence\recovery-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$recoveryEvidence = Get-Content -Raw -LiteralPath $recoveryEvidenceFile.FullName |
  ConvertFrom-Json
$observedRecoveryPercent = [int]$recoveryEvidence.traffic.observedPercent

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-evidence-gate.ps1 `
  -EvidencePath $recoveryEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The artifact must prove an exact 1-10 percent canary. A 100 percent recovery
belongs in continuous production assurance and must not enter this gate.

## 4. Record observation and create the bounded plan

Use exact UTC timestamps and durable references from the owning systems. The
target must be greater than the recovery canary and no higher than 25 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-expansion-plan.ps1 `
  -RecoveryEvidencePath $recoveryEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ExpansionChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE RECOVERY EXPANSION OWNER' `
  -TargetPercent 25 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent $observedRecoveryPercent `
  -TrafficStabilityStatus stable `
  -WorkloadStatus stable `
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
  -ExpansionChangeStatus approved `
  -RecoveryEvidenceGateReference 'REPLACE RECOVERY EVIDENCE GATE REFERENCE' `
  -TrafficObservationReference 'REPLACE TRAFFIC OBSERVATION REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -ExpansionChangeReference 'REPLACE EXPANSION CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE RECOVERY EXPANSION REVIEWER' `
  -ObservationMinutes 15 `
  -MaxRecoveryEvidenceAgeMinutes 60 `
  -PlanValidityMinutes 60 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery-expansion/expansion.json`. It binds
the immutable recovery evidence, exact observation interval and signals,
candidate, current and target percentages, external references, rollback
boundary, and required approval statement.

## 5. Inspect and validate the pending plan

```powershell
$recoveryExpansionPlan = `
  '.shieldward/production-incident-recovery-expansion/expansion.json'

Get-Content -LiteralPath $recoveryExpansionPlan

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-expansion-plan.ps1 `
  -PlanPath $recoveryExpansionPlan `
  -RecoveryEvidencePath $recoveryEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the incident and change IDs, immutable candidate, exact observation
window, current canary, target, rollback target, readiness outcome, and
approval statement. Never edit the generated JSON.

## 6. Approve the exact expansion separately

Copy the exact statement printed by the generator and preserve the same
approval in the authoritative change system.

```powershell
pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-expansion-plan.ps1 `
  -PlanPath $recoveryExpansionPlan `
  -RecoveryEvidencePath $recoveryEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE RECOVERY EXPANSION OWNER' `
  -ApprovalStatement 'REPLACE WITH THE EXACT PRINTED APPROVAL STATEMENT' `
  -CheckCluster
```

The local approval digest detects modification but does not prove identity.
The external incident and change systems remain authoritative.

## 7. Run the final read-only gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-expansion-gate.ps1 `
  -PlanPath $recoveryExpansionPlan `
  -RecoveryEvidencePath $recoveryEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

Only after this gate passes may an authorized operator submit the exact target
to the external traffic controller. The gate does not make that change and
does not prove enforcement.

## 8. Preserve rollback and execution separation

During the externally controlled expansion, keep rollback to the proven
recovery canary immediately available. Disable to zero for security,
correctness, identity, policy, certificate, or unknown-state risk. Preserve
the plan, approval, gate output, controller audit record, monitoring evidence,
and incident/change updates.

After execution, collect a new immutable artifact before any later expansion
or incident closure by following
`docs/production-incident-recovery-expansion-evidence.md`.
An approved plan is intent, not execution evidence.
