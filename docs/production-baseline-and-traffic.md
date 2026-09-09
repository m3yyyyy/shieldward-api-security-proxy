# Production baseline and initial traffic gate

This procedure begins only after an approved first-production installation has
been applied with external traffic disabled. It records a sanitized baseline of
the live digest-pinned workloads, then creates a separate approval plan for a
small initial canary of 1-10 percent.

The scripts are read-only with respect to Kubernetes and the traffic controller.
They inspect resources, run safe health and denial probes inside the existing
pods, and write local evidence beneath `.shieldward`. They do not install,
remove, scale, route, or authorize full production traffic. The production
platform and authoritative change system remain responsible for those actions.

## 1. Prerequisites

Before collecting the baseline, confirm:

1. the approved initial installation plan from
   `docs/initial-production-installation.md` is attached to the change record;
2. the exact candidate image digests are installed in the recorded production
   context;
3. the external traffic controller still blocks production traffic;
4. the real identity-provider and safe idempotent upstream checks passed and
   have a durable evidence reference; and
5. the approved removal procedure has a separate drill-evidence reference.

The collector records external references but cannot verify the external
systems. Missing, vague, or unreviewed references block approval.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-traffic-contract.ps1
```

Its final line must be:

```text
Production baseline and traffic activation planning contract passed.
```

The contract uses synthetic staging, installation, baseline, and approval data.
It never contacts a cluster or traffic controller.

## 3. Collect the traffic-disabled baseline

Select the exact reviewed context and replace every evidence reference:

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'
$initialPlan = '.shieldward/production-initial/installation.json'

kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\new-production-baseline-evidence.ps1 `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -TrafficIsolationEvidenceReference 'REPLACE TRAFFIC ISOLATION EVIDENCE' `
  -AcceptanceEvidenceReference 'REPLACE IDENTITY AND UPSTREAM EVIDENCE' `
  -RemovalDrillEvidenceReference 'REPLACE REMOVAL DRILL EVIDENCE'
```

The collector validates the approved installation plan, current context,
credential Secret names without reading their values, deployment images and
availability, internal-only `ClusterIP` services, and absence of labeled
Ingress resources. It checks the control-plane runtime and probe plus Edge
health, readiness, runtime version, policy continuity, default deny, and
protected-route denial.

Its output is a timestamped file beneath `.shieldward/production-baseline`.
The integrity digest binds the initial plan, live images, deployment and service
snapshots, policy version, traffic-isolation reference, external acceptance
reference, and removal-drill reference.

## 4. Review the baseline

Set the path printed by the collector, inspect it, and validate it locally:

```powershell
$baselineEvidence = '.shieldward/production-baseline/baseline-1.0.0-REPLACE_TIMESTAMP.json'

Get-Content $baselineEvidence

pwsh -NoProfile -File .\scripts\test-production-baseline-evidence.ps1 `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext
```

Changing the baseline, initial plan, or staging evidence blocks validation.
Create fresh evidence rather than editing any JSON record.

## 5. Create a bounded canary plan

Use the smallest cohort supported by the external traffic controller. The gate
rejects values outside 1-10 percent and rejects stale baseline evidence:

```powershell
pwsh -NoProfile -File .\scripts\new-production-traffic-plan.ps1 `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE TRAFFIC APPROVAL OWNER' `
  -CanaryPercent 1 `
  -ObservationMinutes 15 `
  -MaxBaselineAgeMinutes 60
```

The output is `.shieldward/production-traffic/activation.json`. It binds the
fresh traffic-disabled baseline, exact candidate and policy digests, canary
percentage, observation window, traffic controller, and disable-before-removal
path into a tamper-detecting plan.

## 6. Review and approve

Validate the pending plan, then copy the exact statement printed by the
generator:

```powershell
pwsh -NoProfile -File .\scripts\test-production-traffic-plan.ps1 `
  -PlanPath .\.shieldward\production-traffic\activation.json `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending

pwsh -NoProfile -File .\scripts\approve-production-traffic-plan.ps1 `
  -PlanPath .\.shieldward\production-traffic\activation.json `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE TRAFFIC APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE 1% CANARY CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT RELEASE 1.0.0'
```

The local approval digest detects accidental modification but is not a digital
signature. Attach the plan and all referenced evidence to the authoritative
change record.

## 7. Recheck immediately before the canary

```powershell
pwsh -NoProfile -File .\scripts\test-production-traffic-plan.ps1 `
  -PlanPath .\.shieldward\production-traffic\activation.json `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Approved `
  -CheckCluster
```

This rechecks the exact context, live image digests, deployment availability,
internal-only services, absence of labeled Ingress, baseline age, and every
integrity and approval binding. It still does not inspect or change the external
traffic controller.

## 8. Activate and observe the approved canary

Only the named traffic-controller owner may activate exactly the approved
percentage through the approved platform. Record the controller change ID,
operator, timestamp, and observed cohort. Monitor availability, error outcomes,
policy age, rejected reloads, authentication failures, upstream latency,
rate-limit dependency health, circuit transitions, saturation, and draining for
the full observation window.

This plan does not authorize expansion above the recorded percentage. A missing
signal, stale baseline, image drift, policy drift, or exhausted error budget is
a failed gate.

## 9. Stop or establish the first live baseline

On failure, disable traffic first, confirm the cohort is zero, then invoke the
approved removal procedure if required. Preserve evidence and rerun the relevant
read-only checks. Never delete credentials or audit evidence as an incidental
rollback step.

On success, record the exact live image and policy digests as the first verified
production rollback baseline. Later releases must use
`docs/production-promotion.md`. Full traffic expansion remains a separate,
platform-owned approval and is not granted by this initial canary plan.
