# Production full-traffic evidence and steady-state acceptance

This procedure starts only after the exact final expansion in
`docs/production-final-expansion.md` has been approved and enforced by the
authoritative external traffic controller. It records the completed 100
percent observation as tamper-detecting evidence and applies a fail-closed
steady-state acceptance gate.

The approved final expansion plan proves authorization only. It is not proof
that 100 percent traffic was enforced or safely observed. The scripts in this
procedure are read-only with respect to Kubernetes and the traffic controller;
they cannot change, restore, disable, or remove traffic.

## 1. Confirm the evidence boundary

Before collecting evidence, confirm:

1. the approved final expansion plan and authoritative approval are attached to
   the external change record;
2. the external controller independently shows exactly 100 percent traffic;
3. the complete approved observation window elapsed after enforcement;
4. error budget, alerts, protected-route behavior, dependencies, operations,
   capacity, and security signals are all available; and
5. the owner can restore the prior 75 percent cohort immediately and can
   disable traffic before removal for a security or correctness emergency.

Missing, unknown, failed, stale, tampered, or incomplete evidence fails closed
and cannot produce steady-state acceptance.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-steady-state-contract.ps1
```

Its final line must be:

```text
Production full-traffic evidence and steady-state acceptance contract passed.
```

The contract uses synthetic artifacts beneath `.shieldward`. It never contacts
a cluster or traffic controller.

## 3. Record the completed 100 percent observation

Use exact UTC timestamps and references from the authoritative traffic,
monitoring, and change systems. Do not substitute estimates or the local
approval record.

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$finalPlan = '.shieldward/production-final-expansion/expansion.json'
$secondEvidence = '.shieldward/production-second-expansion-evidence/evidence.json'
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

pwsh -NoProfile -File .\scripts\new-production-full-traffic-evidence.ps1 `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
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
  -ObservedTrafficPercent 100 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -TrafficChangeReference 'REPLACE TRAFFIC CHANGE EVIDENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE' `
  -ReviewedBy 'REPLACE REVIEWER' `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear
```

The output is
`.shieldward/production-full-traffic-evidence/evidence.json`. The collector
rechecks the approved final plan, its entire evidence chain, immutable
candidate, exact production context, and live workload state without reading
Secret values or changing traffic.

Record an honest `unknown` or failed signal rather than omitting it. The
artifact will be preserved, but acceptance will be blocked.

## 4. Inspect and validate the evidence

```powershell
Get-Content .\.shieldward\production-full-traffic-evidence\evidence.json

pwsh -NoProfile -File .\scripts\test-production-full-traffic-evidence.ps1 `
  -EvidencePath .\.shieldward\production-full-traffic-evidence\evidence.json `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
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

Changing this evidence or any bound prerequisite blocks validation. Record a
new artifact from authoritative sources instead of editing JSON.

## 5. Apply the steady-state acceptance gate

Run acceptance while the evidence is still within the approved age. The
default maximum is 24 hours; use a narrower reviewed limit when required.

```powershell
pwsh -NoProfile -File .\scripts\test-production-steady-state-acceptance.ps1 `
  -EvidencePath .\.shieldward\production-full-traffic-evidence\evidence.json `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
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
  -MaxEvidenceAgeMinutes 1440 `
  -CheckCluster
```

The gate passes only for fresh, complete, tamper-consistent, passed evidence of
externally enforced and observed 100 percent traffic. Attach the artifact and
validator output to the authoritative change record before closing the rollout.

## 6. Continue monitoring or roll back

Steady-state acceptance closes the rollout gate; it does not end operational
monitoring or make the local file authoritative. Continue normal alerting,
error-budget, security, capacity, dependency, and policy-drift monitoring.

For a load or capacity-only failure with candidate correctness intact, restore
the prior 75 percent cohort through the authoritative controller. For a
security, correctness, policy-drift, identity, or unknown-state failure,
disable traffic first, confirm zero traffic, and invoke the approved removal
procedure if necessary. Preserve the evidence and all external audit records.
