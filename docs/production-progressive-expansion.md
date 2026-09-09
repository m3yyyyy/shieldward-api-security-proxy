# Production first-expansion evidence and progressive gate

This procedure starts only after the separately approved first expansion in
`docs/production-canary-and-expansion.md` has been enforced by the external
traffic controller. It records the completed first-expansion observation as
tamper-detecting evidence, then creates one separately approved progressive
step. The next target may increase by at most 25 percentage points and cannot
exceed 50 percent traffic.

The scripts are read-only with respect to Kubernetes and the traffic
controller. They cannot expand, restore, disable, or remove production traffic.
The production platform and authoritative change system remain responsible for
enforcement. This procedure does not authorize full traffic.

## 1. Confirm the evidence boundary

Before collecting evidence, confirm:

1. the approved first-expansion plan is attached to the external change record;
2. the external controller shows exactly the approved target, no higher than 25
   percent;
3. the complete approved observation window has elapsed;
4. monitoring covers error budget, alerts, protected-route behavior,
   dependencies, saturation, circuits, and draining; and
5. the owner can restore the previous cohort immediately and can disable
   traffic before removal for a security or correctness emergency.

Missing or unknown signals are preserved as evidence but fail closed: they
cannot produce a progressive expansion plan.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-progressive-contract.ps1
```

Its final line must be:

```text
Production first-expansion evidence and progressive planning contract passed.
```

The contract uses synthetic plans and evidence beneath `.shieldward`. It never
contacts a cluster or traffic controller.

## 3. Record the completed first expansion

Use the exact UTC timestamps and references from the authoritative traffic and
monitoring systems. Do not replace them with estimates.

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$expansionPlan = '.shieldward/production-expansion/expansion.json'
$canaryEvidence = '.shieldward/production-canary/evidence.json'
$trafficPlan = '.shieldward/production-traffic/activation.json'
$baselineEvidence = '.shieldward/production-baseline/baseline-1.0.0-REPLACE_TIMESTAMP.json'
$initialPlan = '.shieldward/production-initial/installation.json'
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'

kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\new-production-expansion-evidence.ps1 `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ObservedTrafficPercent 25 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -TrafficChangeReference 'REPLACE TRAFFIC CHANGE EVIDENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE' `
  -ReviewedBy 'REPLACE REVIEWER' `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy
```

The collector rechecks the exact production context, approved expansion plan,
immutable candidate, and live workload state. Its output is
`.shieldward/production-expansion-evidence/evidence.json`. It never reads
Secret values and makes no cluster or traffic changes.

## 4. Inspect and validate the evidence

```powershell
Get-Content .\.shieldward\production-expansion-evidence\evidence.json

pwsh -NoProfile -File .\scripts\test-production-expansion-evidence.ps1 `
  -EvidencePath .\.shieldward\production-expansion-evidence\evidence.json `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Changing the evidence or any prerequisite plan blocks validation. Record a new
artifact from authoritative sources instead of editing JSON.

## 5. Create a bounded progressive plan

Choose a target greater than the observed first expansion. The increase cannot
exceed 25 percentage points and the resulting target cannot exceed 50 percent.

```powershell
pwsh -NoProfile -File .\scripts\new-production-progressive-plan.ps1 `
  -ExpansionEvidencePath .\.shieldward\production-expansion-evidence\evidence.json `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE PROGRESSIVE APPROVAL OWNER' `
  -TargetPercent 50 `
  -ObservationMinutes 15 `
  -MaxEvidenceAgeMinutes 60
```

The output is `.shieldward/production-progressive/expansion.json`. It binds the
passed evidence, immutable candidate, current and target percentages, maximum
step, external controller, observation window, and rollback boundary.

## 6. Review and approve separately

```powershell
pwsh -NoProfile -File .\scripts\test-production-progressive-plan.ps1 `
  -PlanPath .\.shieldward\production-progressive\expansion.json `
  -ExpansionEvidencePath .\.shieldward\production-expansion-evidence\evidence.json `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending

pwsh -NoProfile -File .\scripts\approve-production-progressive-plan.ps1 `
  -PlanPath .\.shieldward\production-progressive\expansion.json `
  -ExpansionEvidencePath .\.shieldward\production-expansion-evidence\evidence.json `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE PROGRESSIVE APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE EXPANSION TO 50% CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT RELEASE 1.0.0'
```

Copy the exact statement printed by the generator. The local digest detects
modification but does not prove identity; retain the authoritative approval in
the external change system.

## 7. Recheck immediately before expansion

```powershell
pwsh -NoProfile -File .\scripts\test-production-progressive-plan.ps1 `
  -PlanPath .\.shieldward\production-progressive\expansion.json `
  -ExpansionEvidencePath .\.shieldward\production-expansion-evidence\evidence.json `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Approved `
  -CheckCluster
```

Only after this read-only gate passes may the operator submit the approved
percentage to the authoritative controller. Observe the full new window before
considering another change. A 50 percent result is not approval for full
traffic.

## 8. Stop or roll back on failure

For a load or capacity-only failure with candidate correctness intact, restore
the previous approved cohort through the authoritative controller. For a
security, correctness, policy-drift, identity, or unknown-state failure, disable
traffic first, confirm zero traffic, and invoke the approved removal procedure
if necessary. Preserve all evidence and external audit records.
