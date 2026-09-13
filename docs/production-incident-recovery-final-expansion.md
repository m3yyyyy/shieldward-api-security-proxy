# Production recovery final expansion observation and gate

Use this procedure only after
`docs/production-incident-recovery-second-expansion-evidence.md` proves an externally
enforced 75 percent second-expansion recovery boundary. It records a completed
observation of that exact boundary and creates one separately approved second
expansion. The increase is capped at 25 percentage points and 100 percent total
traffic.

The scripts validate supplied evidence and approval records. They never route
traffic, mutate workloads, close the incident, or prove that the approved
expansion was executed. The authoritative traffic, monitoring, incident, and
change systems remain the source of truth.

## 1. Hold and observe the proven second expansion boundary

Keep traffic at the 75 percent boundary proven by the second-expansion execution artifact
for the full approved observation window. Preserve durable external evidence
for:

1. stable traffic and workloads at the exact second expansion boundary;
2. error-budget consumption, alerts, functional checks, dependencies,
   operations, and capacity;
3. security, policy/configuration drift, and certificate health;
4. immediate rollback to the second expansion boundary and emergency
   disable-to-zero;
5. the updated incident record; and
6. a separate, approved final-expansion recovery change record.

Failed, degraded, unknown, missing, pending, stale, incomplete, or tampered
evidence fails closed. A healthy observation does not itself authorize a
traffic increase.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-contract.ps1
```

Its final line must be:

```text
Production recovery final expansion observation and planning contract passed.
```

The test uses only synthetic artifacts beneath `.shieldward`. It proves a
bounded 75-to-100-percent plan and rejects failed execution evidence, targets
other than 100 percent, mismatched traffic, degraded or unknown signals, a pending
external change, an incomplete observation, invalid approval, and tampering.

## 3. Select the passed second-expansion execution artifact

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$secondExpansionEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-second-expansion-evidence\second-expansion-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$secondExpansionEvidence = Get-Content -Raw `
  -LiteralPath $secondExpansionEvidenceFile.FullName |
  ConvertFrom-Json
$observedSecondExpansionPercent = [int]$secondExpansionEvidence.traffic.observedPercent

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-evidence-gate.ps1 `
  -EvidencePath $secondExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The artifact must prove an exact 75 percent externally enforced boundary.
Failed, unknown, or mismatched execution evidence must not enter this gate.

## 4. Record observation and create the bounded plan

Use exact UTC timestamps and durable references from the owning systems. The
target must be greater than the second expansion boundary, no more than 25
percentage points above it, and exactly 100 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-final-expansion-plan.ps1 `
  -SecondExpansionEvidencePath $secondExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -FinalExpansionChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE RECOVERY FINAL EXPANSION OWNER' `
  -TargetPercent 100 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent $observedSecondExpansionPercent `
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
  -FinalExpansionChangeStatus approved `
  -PreviousExecutionGateReference 'REPLACE PROGRESSIVE EXECUTION GATE REFERENCE' `
  -TrafficObservationReference 'REPLACE TRAFFIC OBSERVATION REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -FinalExpansionChangeReference 'REPLACE FINAL EXPANSION CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE RECOVERY FINAL EXPANSION REVIEWER' `
  -ObservationMinutes 15 `
  -MaxSecondExpansionEvidenceAgeMinutes 60 `
  -PlanValidityMinutes 60 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery-final-expansion/expansion.json`. It
binds the immutable second expansion execution evidence, exact observation interval
and signals, candidate, current and target percentages, external references,
rollback boundary, and required approval statement.

## 5. Inspect and validate the pending plan

```powershell
$recoveryFinalExpansionPlan = `
  '.shieldward/production-incident-recovery-final-expansion/expansion.json'

Get-Content -LiteralPath $recoveryFinalExpansionPlan

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-plan.ps1 `
  -PlanPath $recoveryFinalExpansionPlan `
  -SecondExpansionEvidencePath $secondExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the incident and change IDs, immutable candidate, exact observation
window, current boundary, target, rollback target, readiness outcome, and
approval statement. Never edit the generated JSON.

## 6. Approve the exact final expansion separately

Copy the exact statement printed by the generator and preserve the same
approval in the authoritative change system.

```powershell
pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-final-expansion-plan.ps1 `
  -PlanPath $recoveryFinalExpansionPlan `
  -SecondExpansionEvidencePath $secondExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE RECOVERY FINAL EXPANSION OWNER' `
  -ApprovalStatement 'REPLACE WITH THE EXACT PRINTED APPROVAL STATEMENT' `
  -CheckCluster
```

The local approval digest detects modification but does not prove identity.
The external incident and change systems remain authoritative.

## 7. Run the final read-only authorization gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-final-expansion-gate.ps1 `
  -PlanPath $recoveryFinalExpansionPlan `
  -SecondExpansionEvidencePath $secondExpansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

Only after this gate passes may an authorized operator submit the exact target
to the external traffic controller. The gate does not make that change and
does not prove enforcement.

## 8. Preserve rollback and execution separation

During the externally controlled expansion, keep rollback to the proven
75 percent recovery boundary immediately available. Disable to zero for
security, correctness, identity, policy, certificate, or unknown-state risk.
Preserve the plan, approval, gate output, controller audit record, monitoring
evidence, and incident/change updates.

After execution, follow
`docs/production-incident-recovery-final-expansion-evidence.md` and collect a
new immutable execution-evidence artifact before production re-acceptance or
incident-closure review. Do not reuse the second-expansion evidence as proof
of this final-expansion action. An approved plan is intent, not execution
evidence, and reaching 100 percent does not automatically close the incident.
