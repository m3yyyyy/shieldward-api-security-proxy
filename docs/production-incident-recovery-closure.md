# Production recovery re-acceptance and incident-closure gate

Use this procedure only after
`docs/production-incident-recovery-final-expansion-evidence.md` proves that the
approved release is externally enforced at exactly 100 percent production
traffic. This gate holds that boundary, evaluates sustained health and an
independent production re-acceptance, and records a separately approved
incident-closure decision.

The scripts are read-only with respect to production. They do not route
traffic, mutate workloads, or close the incident. The authoritative traffic,
monitoring, incident, and change systems remain the source of truth.

## 1. Hold 100 percent and collect independent evidence

Keep traffic at the proven 100 percent boundary for the full observation
window. Preserve durable references for:

1. stable traffic, workloads, error budget, alerts, and functional checks;
2. healthy dependencies, operations, capacity, security, certificates, and
   configuration or policy drift;
3. rollback readiness to the previous 75 percent recovery boundary, with
   emergency disable-to-zero still available;
4. an independent production re-acceptance result;
5. the updated incident record; and
6. a separate incident-closure change record.

Failed, degraded, unknown, missing, pending, stale, incomplete, or tampered
evidence fails closed. A healthy observation does not close the incident.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-contract.ps1
```

Its final line must be:

```text
Production recovery incident closure observation and planning contract passed.
```

The contract uses only synthetic artifacts beneath `.shieldward`. It rejects
failed final-expansion evidence, any boundary other than 100 percent, traffic
mutation, degraded or unknown signals, failed re-acceptance, a pending closure
change, incomplete observation, invalid approval, and tampering.

## 3. Select the passed final-expansion evidence

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$finalExpansionEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-final-expansion-evidence\final-expansion-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$finalExpansionEvidence = Get-Content -Raw `
  -LiteralPath $finalExpansionEvidenceFile.FullName |
  ConvertFrom-Json
$observedFinalPercent = [int]$finalExpansionEvidence.traffic.observedPercent

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-evidence-gate.ps1 `
  -EvidencePath $finalExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The artifact must prove an exact 100 percent externally enforced boundary and
a passed outcome. Do not use failed or unknown execution evidence.

## 4. Create the incident-closure readiness plan

Use exact UTC timestamps and durable references from the owning systems.
Independent re-acceptance must be `passed`, the closure change must be
`approved`, and traffic must remain at 100 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-closure-plan.ps1 `
  -FinalExpansionEvidencePath $finalExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ClosureChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE RECOVERY INCIDENT CLOSURE OWNER' `
  -HoldTrafficPercent 100 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent $observedFinalPercent `
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
  -ReacceptanceStatus passed `
  -IncidentRecordStatus updated `
  -ClosureChangeStatus approved `
  -PreviousExecutionGateReference 'REPLACE FINAL EXPANSION EXECUTION GATE REFERENCE' `
  -TrafficObservationReference 'REPLACE TRAFFIC OBSERVATION REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -ReacceptanceEvidenceReference 'REPLACE INDEPENDENT REACCEPTANCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -ClosureChangeReference 'REPLACE INCIDENT CLOSURE CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE INDEPENDENT RECOVERY CLOSURE REVIEWER' `
  -ObservationMinutes 15 `
  -MaxFinalExpansionEvidenceAgeMinutes 60 `
  -PlanValidityMinutes 60 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery-closure/closure.json`. It binds the
immutable final-expansion evidence, exact observation window, independent
re-acceptance, external records, 100 percent hold, rollback to 75 percent, and
the exact approval statement.

## 5. Inspect and validate the pending plan

```powershell
$recoveryClosurePlan = `
  '.shieldward/production-incident-recovery-closure/closure.json'

Get-Content -LiteralPath $recoveryClosurePlan

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-plan.ps1 `
  -PlanPath $recoveryClosurePlan `
  -FinalExpansionEvidencePath $finalExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the incident and change IDs, immutable release, observation interval,
re-acceptance result, hold and rollback boundaries, readiness outcome, and
approval statement. Never edit the generated JSON.

## 6. Approve closure separately

Copy the exact statement printed by the generator and preserve the same
approval in the authoritative change or incident system.

```powershell
pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-closure-plan.ps1 `
  -PlanPath $recoveryClosurePlan `
  -FinalExpansionEvidencePath $finalExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE RECOVERY INCIDENT CLOSURE OWNER' `
  -ApprovalStatement 'REPLACE WITH THE EXACT PRINTED APPROVAL STATEMENT' `
  -CheckCluster
```

The local digest detects modification but does not prove identity. Approval is
intent only; this script does not close the incident.

## 7. Run the final read-only closure gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-gate.ps1 `
  -PlanPath $recoveryClosurePlan `
  -FinalExpansionEvidencePath $finalExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

Only after this gate passes may an authorized operator close the recovery
incident through the authoritative external system after independent review.
The gate itself does not close anything or change traffic.

## 8. Preserve rollback and audit evidence

Until external closure is confirmed, keep the 100 percent hold and the
rollback-to-75 procedure ready. Disable to zero for security, correctness,
identity, policy, certificate, or unknown-state risk. Preserve the final
expansion evidence, closure plan, approval digest, gate output, independent
re-acceptance, monitoring evidence, and incident/change records. Never treat
the local plan or gate output as proof that the external incident was closed.
