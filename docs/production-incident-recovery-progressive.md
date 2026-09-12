# Production recovery progressive observation and expansion gate

Use this procedure only after
`docs/production-incident-recovery-expansion-evidence.md` proves an externally
enforced 2-25 percent recovery expansion boundary. It records a completed
observation of that boundary and creates one separately approved progressive
expansion. The increase is capped at 25 percentage points and 50 percent total
traffic.

The scripts validate supplied evidence and approval records. They never route
traffic, mutate workloads, close the incident, or prove that the approved
expansion was executed. The authoritative traffic, monitoring, incident, and
change systems remain the source of truth.

## 1. Hold and observe the exact recovery expansion boundary

Keep traffic at the percentage proven by the recovery expansion execution artifact for
the full approved observation window. Preserve durable external evidence for:

1. stable traffic and workloads at the exact recovery expansion boundary;
2. error-budget consumption, alerts, functional checks, dependencies,
   operations, and capacity;
3. security, policy/configuration drift, and certificate health;
4. immediate rollback to the recovery expansion boundary and emergency disable-to-zero;
5. the updated incident record; and
6. a separate, approved progressive recovery change record.

Failed, degraded, unknown, missing, pending, stale, incomplete, or tampered
evidence fails closed. A healthy observation does not itself authorize a
traffic increase.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-progressive-contract.ps1
```

Its final line must be:

```text
Production recovery progressive observation and expansion planning contract passed.
```

The test uses only synthetic artifacts beneath `.shieldward`. It proves a
bounded 25-to-50-percent plan and rejects failed execution evidence, oversized targets,
degraded or unknown signals, a pending external change, an incomplete
observation, invalid approval, and tampering.

## 3. Select the passed recovery expansion execution artifact

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$expansionEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-expansion-evidence\expansion-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$expansionEvidence = Get-Content -Raw -LiteralPath $expansionEvidenceFile.FullName |
  ConvertFrom-Json
$observedExpansionPercent = [int]$expansionEvidence.traffic.observedPercent

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-expansion-evidence-gate.ps1 `
  -EvidencePath $expansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The artifact must prove an exact 2-25 percent externally enforced boundary.
Failed, unknown, or mismatched execution evidence must not enter this gate.

## 4. Record observation and create the bounded plan

Use exact UTC timestamps and durable references from the owning systems. The
target must be greater than the recovery expansion boundary, no more than 25
percentage points above it, and no higher than 50 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-progressive-plan.ps1 `
  -ExpansionEvidencePath $expansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ProgressiveChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE RECOVERY PROGRESSIVE OWNER' `
  -TargetPercent 50 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent $observedExpansionPercent `
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
  -ProgressiveChangeStatus approved `
  -PreviousExecutionGateReference 'REPLACE EXPANSION EXECUTION GATE REFERENCE' `
  -TrafficObservationReference 'REPLACE TRAFFIC OBSERVATION REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -ProgressiveChangeReference 'REPLACE PROGRESSIVE CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE RECOVERY PROGRESSIVE REVIEWER' `
  -ObservationMinutes 15 `
  -MaxExpansionEvidenceAgeMinutes 60 `
  -PlanValidityMinutes 60 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery-progressive/expansion.json`. It binds
the immutable expansion execution evidence, exact observation interval and signals,
candidate, current and target percentages, external references, rollback
boundary, and required approval statement.

## 5. Inspect and validate the pending plan

```powershell
$recoveryProgressivePlan = `
  '.shieldward/production-incident-recovery-progressive/expansion.json'

Get-Content -LiteralPath $recoveryProgressivePlan

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-progressive-plan.ps1 `
  -PlanPath $recoveryProgressivePlan `
  -ExpansionEvidencePath $expansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the incident and change IDs, immutable candidate, exact observation
window, current boundary, target, rollback target, readiness outcome, and
approval statement. Never edit the generated JSON.

## 6. Approve the exact progressive expansion separately

Copy the exact statement printed by the generator and preserve the same
approval in the authoritative change system.

```powershell
pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-progressive-plan.ps1 `
  -PlanPath $recoveryProgressivePlan `
  -ExpansionEvidencePath $expansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE RECOVERY PROGRESSIVE OWNER' `
  -ApprovalStatement 'REPLACE WITH THE EXACT PRINTED APPROVAL STATEMENT' `
  -CheckCluster
```

The local approval digest detects modification but does not prove identity.
The external incident and change systems remain authoritative.

## 7. Run the final read-only gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-progressive-gate.ps1 `
  -PlanPath $recoveryProgressivePlan `
  -ExpansionEvidencePath $expansionEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

Only after this gate passes may an authorized operator submit the exact target
to the external traffic controller. The gate does not make that change and
does not prove enforcement.

## 8. Preserve rollback and execution separation

During the externally controlled expansion, keep rollback to the proven
previous recovery boundary immediately available. Disable to zero for security,
correctness, identity, policy, certificate, or unknown-state risk. Preserve
the plan, approval, gate output, controller audit record, monitoring evidence,
and incident/change updates.

After execution, collect a new immutable artifact before any later expansion
or incident closure. Do not reuse the prior expansion evidence as proof of this
progressive action. An approved plan is intent, not execution evidence.
