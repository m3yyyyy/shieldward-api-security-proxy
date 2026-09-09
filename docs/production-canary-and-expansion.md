# Production canary evidence and first expansion gate

This procedure starts only after the initial 1-10 percent production canary in
`docs/production-baseline-and-traffic.md` has been explicitly approved and
activated by the external traffic controller. It records the completed canary
observation as tamper-detecting evidence, then creates a separate approval plan
for one bounded expansion that cannot exceed 25 percent traffic.

The scripts are read-only with respect to Kubernetes and the traffic
controller. They cannot activate, expand, disable, or remove production
traffic. The production platform and authoritative change system remain
responsible for those operations.

## 1. Preconditions

Before collecting evidence, confirm:

1. the approved initial traffic plan and traffic-disabled baseline are attached
   to the change record;
2. the external controller shows exactly the approved canary percentage;
3. the complete approved observation window has elapsed;
4. monitoring covers readiness, error outcomes, policy continuity,
   authentication, upstream latency, rate-limit dependencies, circuits,
   saturation, and draining; and
5. the disable-before-removal owner remains available.

Missing or unknown signals are preserved as evidence but fail closed: they
cannot produce an expansion plan.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-expansion-contract.ps1
```

Its final line must be:

```text
Production canary evidence and first expansion planning contract passed.
```

The contract uses synthetic plans and evidence beneath `.shieldward`. It never
contacts a cluster or traffic controller.

## 3. Record the completed canary observation

Use the exact UTC timestamps from the authoritative traffic and monitoring
systems. Do not substitute the current time if those systems recorded a
different interval.

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$trafficPlan = '.shieldward/production-traffic/activation.json'
$baselineEvidence = '.shieldward/production-baseline/baseline-1.0.0-REPLACE_TIMESTAMP.json'
$initialPlan = '.shieldward/production-initial/installation.json'
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'

kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\new-production-canary-evidence.ps1 `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ObservedCanaryPercent 1 `
  -ObservationStartedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -ObservationEndedAtUtc 'REPLACE_WITH_UTC_TIMESTAMP' `
  -TrafficChangeReference 'REPLACE TRAFFIC CHANGE EVIDENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE' `
  -ReviewedBy 'REPLACE CANARY REVIEWER' `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy
```

The collector validates the approved traffic plan for post-activation evidence,
rechecks the exact production context and digest-pinned live workloads, and
repeats the safe health, readiness, policy, default-deny, and protected-route
checks. It never reads Secret values. Its output is
`.shieldward/production-canary/evidence.json`.

The outcome is computed from the recorded signals. Any exhausted budget,
firing alert, failed functional result, degraded dependency, degraded
operational result, or unknown status prevents expansion.

## 4. Inspect and validate the evidence

```powershell
Get-Content .\.shieldward\production-canary\evidence.json

pwsh -NoProfile -File .\scripts\test-production-canary-evidence.ps1 `
  -EvidencePath .\.shieldward\production-canary\evidence.json `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Changing the evidence or any prerequisite plan blocks validation. Create a new
record from authoritative sources instead of editing JSON.

## 5. Create a bounded first-expansion plan

Choose a target greater than the observed canary and no greater than 25
percent. The gate rejects stale or non-passing canary evidence.

```powershell
pwsh -NoProfile -File .\scripts\new-production-expansion-plan.ps1 `
  -CanaryEvidencePath .\.shieldward\production-canary\evidence.json `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE EXPANSION APPROVAL OWNER' `
  -TargetPercent 25 `
  -ObservationMinutes 15 `
  -MaxEvidenceAgeMinutes 60
```

The output is `.shieldward/production-expansion/expansion.json`. It binds the
passed evidence, immutable images and policy, current and target percentages,
external controller, observation window, and disable-before-removal path.

## 6. Review and approve separately

```powershell
pwsh -NoProfile -File .\scripts\test-production-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-expansion\expansion.json `
  -CanaryEvidencePath .\.shieldward\production-canary\evidence.json `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending

pwsh -NoProfile -File .\scripts\approve-production-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-expansion\expansion.json `
  -CanaryEvidencePath .\.shieldward\production-canary\evidence.json `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE EXPANSION APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE EXPANSION TO 25% CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT RELEASE 1.0.0'
```

Copy the exact statement printed by the generator. The local digest detects
modification but does not prove identity; retain the authoritative approval in
the external change system.

## 7. Recheck immediately before expansion

```powershell
pwsh -NoProfile -File .\scripts\test-production-expansion-plan.ps1 `
  -PlanPath .\.shieldward\production-expansion\expansion.json `
  -CanaryEvidencePath .\.shieldward\production-canary\evidence.json `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Approved `
  -CheckCluster
```

Only the named traffic-controller owner may then apply exactly the approved
target. Observe the expanded cohort for the full new window. This plan does not
authorize any later step or full traffic.

## 8. Stop on failure

Any missing signal, exhausted budget, alert, drift, or failed probe blocks the
expansion. Disable traffic first through the authoritative controller, confirm
the cohort is zero, and invoke the approved removal path if required. Preserve
all evidence. Do not delete credentials or audit records as an incidental
rollback action.
