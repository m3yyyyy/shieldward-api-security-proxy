# Production recovery second expansion observation and gate

Use this procedure only after
`docs/production-incident-recovery-progressive-evidence.md` proves an externally
enforced 3-50 percent progressive recovery boundary. It records a completed
observation of that exact boundary and creates one separately approved second
expansion. The increase is capped at 25 percentage points and 75 percent total
traffic.

The scripts validate supplied evidence and approval records. They never route
traffic, mutate workloads, close the incident, or prove that the approved
expansion was executed. The authoritative traffic, monitoring, incident, and
change systems remain the source of truth.

## 1. Hold and observe the proven progressive boundary

Keep traffic at the percentage proven by the progressive execution artifact
for the full approved observation window. Preserve durable external evidence
for:

1. stable traffic and workloads at the exact progressive boundary;
2. error-budget consumption, alerts, functional checks, dependencies,
   operations, and capacity;
3. security, policy/configuration drift, and certificate health;
4. immediate rollback to the progressive boundary and emergency
   disable-to-zero;
5. the updated incident record; and
6. a separate, approved second-expansion recovery change record.

Failed, degraded, unknown, missing, pending, stale, incomplete, or tampered
evidence fails closed. A healthy observation does not itself authorize a
traffic increase.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-contract.ps1
```

Its final line must be:

```text
Production recovery second expansion observation and planning contract passed.
```

The test uses only synthetic artifacts beneath `.shieldward`. It proves a
bounded 50-to-75-percent plan and rejects failed execution evidence, targets
above 75 percent, mismatched traffic, degraded or unknown signals, a pending
external change, an incomplete observation, invalid approval, and tampering.

## 3. Select the passed progressive execution artifact

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$progressiveEvidenceFile = Get-ChildItem `
  .\.shieldward\production-incident-recovery-progressive-evidence\progressive-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$progressiveEvidence = Get-Content -Raw `
  -LiteralPath $progressiveEvidenceFile.FullName |
  ConvertFrom-Json
$observedProgressivePercent = [int]$progressiveEvidence.traffic.observedPercent

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-progressive-evidence-gate.ps1 `
  -EvidencePath $progressiveEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The artifact must prove an exact 3-50 percent externally enforced boundary.
Failed, unknown, or mismatched execution evidence must not enter this gate.

## 4. Record observation and create the bounded plan

Use exact UTC timestamps and durable references from the owning systems. The
target must be greater than the progressive boundary, no more than 25
percentage points above it, and no higher than 75 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-incident-recovery-second-expansion-plan.ps1 `
  -ProgressiveEvidencePath $progressiveEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -SecondExpansionChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE RECOVERY SECOND EXPANSION OWNER' `
  -TargetPercent 75 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservedTrafficPercent $observedProgressivePercent `
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
  -SecondExpansionChangeStatus approved `
  -PreviousExecutionGateReference 'REPLACE PROGRESSIVE EXECUTION GATE REFERENCE' `
  -TrafficObservationReference 'REPLACE TRAFFIC OBSERVATION REFERENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE REFERENCE' `
  -RollbackEvidenceReference 'REPLACE ROLLBACK EVIDENCE REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -SecondExpansionChangeReference 'REPLACE SECOND EXPANSION CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE RECOVERY SECOND EXPANSION REVIEWER' `
  -ObservationMinutes 15 `
  -MaxProgressiveEvidenceAgeMinutes 60 `
  -PlanValidityMinutes 60 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery-second-expansion/expansion.json`. It
binds the immutable progressive execution evidence, exact observation interval
and signals, candidate, current and target percentages, external references,
rollback boundary, and required approval statement.

## 5. Inspect and validate the pending plan

```powershell
$recoverySecondExpansionPlan = `
  '.shieldward/production-incident-recovery-second-expansion/expansion.json'

Get-Content -LiteralPath $recoverySecondExpansionPlan

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-plan.ps1 `
  -PlanPath $recoverySecondExpansionPlan `
  -ProgressiveEvidencePath $progressiveEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the incident and change IDs, immutable candidate, exact observation
window, current boundary, target, rollback target, readiness outcome, and
approval statement. Never edit the generated JSON.

## 6. Approve the exact second expansion separately

Copy the exact statement printed by the generator and preserve the same
approval in the authoritative change system.

```powershell
pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-second-expansion-plan.ps1 `
  -PlanPath $recoverySecondExpansionPlan `
  -ProgressiveEvidencePath $progressiveEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE RECOVERY SECOND EXPANSION OWNER' `
  -ApprovalStatement 'REPLACE WITH THE EXACT PRINTED APPROVAL STATEMENT' `
  -CheckCluster
```

The local approval digest detects modification but does not prove identity.
The external incident and change systems remain authoritative.

## 7. Run the final read-only gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-second-expansion-gate.ps1 `
  -PlanPath $recoverySecondExpansionPlan `
  -ProgressiveEvidencePath $progressiveEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

Only after this gate passes may an authorized operator submit the exact target
to the external traffic controller. The gate does not make that change and
does not prove enforcement.

## 8. Preserve rollback and execution separation

During the externally controlled expansion, keep rollback to the proven
progressive recovery boundary immediately available. Disable to zero for
security, correctness, identity, policy, certificate, or unknown-state risk.
Preserve the plan, approval, gate output, controller audit record, monitoring
evidence, and incident/change updates.

After execution, collect a new immutable execution-evidence artifact before
any later expansion or incident closure. Do not reuse the progressive evidence
as proof of this second-expansion action. An approved plan is intent, not
execution evidence.
