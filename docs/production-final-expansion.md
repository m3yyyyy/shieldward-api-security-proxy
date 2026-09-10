# Production second-expansion evidence and final expansion gate

This procedure starts only after the separately approved 75 percent expansion
in `docs/production-second-expansion.md` has been enforced by the external
traffic controller. It records the completed 75 percent observation as
tamper-detecting evidence, then creates a separate, exact 75-to-100-percent
approval gate.

The scripts are read-only with respect to Kubernetes and the traffic
controller. They cannot expand, restore, disable, or remove production traffic.
The production platform and authoritative change system remain responsible for
enforcement. A generated plan is not approval, and an approved local plan is
not proof that full traffic was enforced.

## 1. Confirm the evidence boundary

Before collecting evidence, confirm:

1. the approved second-expansion plan is attached to the external change record;
2. the external controller shows exactly 75 percent traffic;
3. the complete approved observation window has elapsed;
4. monitoring covers error budget, alerts, protected-route behavior,
   dependencies, saturation, circuits, and draining; and
5. the owner can restore the previous 75 percent cohort immediately and can
   disable traffic before removal for a security or correctness emergency.

Missing or unknown signals are preserved as evidence but fail closed. Stale,
tampered, failed, or incomplete evidence cannot produce a final expansion plan.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-final-expansion-contract.ps1
```

Its final line must be:

```text
Production second-expansion evidence and final expansion planning contract passed.
```

The contract uses synthetic plans and evidence beneath `.shieldward`. It never
contacts a cluster or traffic controller.

## 3. Record the completed 75 percent observation

Use exact UTC timestamps and references from the authoritative traffic and
monitoring systems. Do not replace them with estimates.

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$secondPlan = '.shieldward/production-second-expansion/expansion.json'
$progressiveEvidence = '.shieldward/production-progressive-evidence/evidence.json'
$progressivePlan = '.shieldward/production-progressive/expansion.json'
$expansionEvidence = '.shieldward/production-expansion-evidence/evidence.json'
$expansionPlan = '.shieldward/production-expansion/expansion.json'
$canaryEvidence = '.shieldward/production-canary/evidence.json'
$trafficPlan = '.shieldward/production-traffic/activation.json'
$baselineEvidence = '.shieldward/production-baseline/baseline-1.0.0-REPLACE_TIMESTAMP.json'
$initialPlan = '.shieldward/production-initial/installation.json'
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'

kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\new-production-second-expansion-evidence.ps1 `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ObservedTrafficPercent 75 `
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

The output is
`.shieldward/production-second-expansion-evidence/evidence.json`. The collector
rechecks the approved plan, immutable candidate, exact production context, and
live workload state without reading Secret values or changing traffic.

## 4. Inspect and validate the evidence

```powershell
Get-Content .\.shieldward\production-second-expansion-evidence\evidence.json

pwsh -NoProfile -File .\scripts\test-production-second-expansion-evidence.ps1 `
  -EvidencePath .\.shieldward\production-second-expansion-evidence\evidence.json `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Changing this evidence or any prerequisite plan blocks validation. Record a new
artifact from authoritative sources instead of editing JSON.

## 5. Create the exact final expansion plan

The source cohort must be exactly 75 percent and the target must be exactly 100
percent. No other source or target is accepted.

```powershell
pwsh -NoProfile -File .\scripts\new-production-final-expansion-plan.ps1 `
  -SecondExpansionEvidencePath .\.shieldward\production-second-expansion-evidence\evidence.json `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE FINAL EXPANSION APPROVAL OWNER' `
  -TargetPercent 100 `
  -ObservationMinutes 15 `
  -MaxEvidenceAgeMinutes 60
```

The output is `.shieldward/production-final-expansion/expansion.json`. It binds
the passed 75 percent evidence, immutable candidate, exact target, observation
window, external controller, and rollback to the previous 75 percent cohort.

## 6. Review and approve separately

```powershell
pwsh -NoProfile -File .\scripts\test-production-final-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-final-expansion\expansion.json `
  -SecondExpansionEvidencePath .\.shieldward\production-second-expansion-evidence\evidence.json `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending

pwsh -NoProfile -File .\scripts\approve-production-final-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-final-expansion\expansion.json `
  -SecondExpansionEvidencePath .\.shieldward\production-second-expansion-evidence\evidence.json `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE FINAL EXPANSION APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE FINAL EXPANSION TO 100% CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT RELEASE 1.0.0'
```

Copy the exact statement printed by the generator. The local digest detects
modification but does not prove identity; retain the authoritative approval in
the external change system.

## 7. Recheck immediately before full traffic

```powershell
pwsh -NoProfile -File .\scripts\test-production-final-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-final-expansion\expansion.json `
  -SecondExpansionEvidencePath .\.shieldward\production-second-expansion-evidence\evidence.json `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
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

Only after that read-only gate passes may the operator submit the exact 100
percent target to the authoritative controller. Observe the full approved
window after enforcement and retain operational evidence separately.

## 8. Stop or roll back on failure

For a load or capacity-only failure with candidate correctness intact, restore
the previous 75 percent cohort through the authoritative controller. For a
security, correctness, policy-drift, identity, or unknown-state failure,
disable traffic first, confirm zero traffic, and invoke the approved removal
procedure if necessary. Preserve all evidence and external audit records.

After 100 percent traffic has been externally enforced and the complete
observation window has elapsed, continue with
`docs/production-steady-state.md`. The approved plan is authorization, not
proof of enforcement or steady-state health.
