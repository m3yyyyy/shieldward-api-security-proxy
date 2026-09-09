# Production promotion decision gate

Production promotion begins only after a released candidate has passed the
digest-pinned staging rollout and control-plane outage drill. The scripts in
this procedure turn that staging result into a tamper-evident, explicitly
approved promotion plan with known rollback images.

This is an operator decision gate. It does not deploy workloads, route traffic,
or replace the authoritative approval in the organization's change system. The
production platform or GitOps workflow remains responsible for applying the
approved images and controlling the canary cohort.

## 1. Required inputs

Before creating a plan, record:

1. the sanitized staging evidence produced by
   `scripts/invoke-staging-rollout.ps1` with the outage drill enabled;
2. an exact production Kubernetes context name that differs from staging;
3. a change-record identifier, approval owner, and rollback authority;
4. the version and immutable control-plane and Edge digests currently verified
   in production as the rollback baseline;
5. an observation window between 5 minutes and 24 hours; and
6. the environment-specific canary, traffic-routing, monitoring, and rollback
   commands approved by the production platform owner.

The gate requires an existing rollback baseline. For the first production
installation, keep traffic disabled and follow the organization's initial
deployment procedure until a healthy baseline and tested removal path have
been recorded. Do not invent a previous digest or describe "no rollback" as a
tested rollback.

Use the repository's fail-closed first-install procedure in
`docs/initial-production-installation.md` to bind that initial deployment to
verified staging evidence, an empty target, explicit approval, disabled
traffic, and an approved removal path.

## 2. Generate a pending plan

Run from the repository root and replace every example value. The staging
evidence and generated plan must remain beneath the ignored `.shieldward`
directory:

```powershell
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'

pwsh -NoProfile -File .\scripts\new-production-promotion-plan.ps1 `
  -StagingEvidencePath $stagingEvidence `
  -ProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE APPROVAL OWNER' `
  -RollbackAuthority 'REPLACE ROLLBACK AUTHORITY' `
  -RollbackVersion 'REPLACE_PREVIOUS_VERSION' `
  -RollbackControlPlaneDigest 'sha256:REPLACE_WITH_64_HEX_CHARACTERS' `
  -RollbackEdgeDigest 'sha256:REPLACE_WITH_64_HEX_CHARACTERS' `
  -ObservationMinutes 15
```

The generator independently checks the staging release metadata, both staged
image references, runtime versions, deployment availability, policy continuity,
default-deny response, protected-route denial, control-plane outage behavior,
and recovery. It rejects a production context equal to staging and rollback
digests equal to the candidate digests.

The output is `.shieldward/production/promotion.json`. It contains no
credentials. Its integrity digest covers the staging evidence hash, production
context, change identifier, candidate and rollback images, observation window,
approval owner, and rollback authority.

## 3. Validate before approval

Review the JSON and validate its pending state without contacting a cluster:

```powershell
Get-Content .\.shieldward\production\promotion.json

pwsh -NoProfile -File .\scripts\test-production-promotion-plan.ps1 `
  -PlanPath .\.shieldward\production\promotion.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending
```

Changing the recorded staging evidence or any integrity-covered plan field
blocks validation. If an input changes, create and review a new pending plan;
do not hand-edit the JSON.

## 4. Record explicit approval

Copy the exact approval statement printed by the generator. The approver name
must exactly match the owner recorded in the plan:

```powershell
pwsh -NoProfile -File .\scripts\approve-production-promotion.ps1 `
  -PlanPath .\.shieldward\production\promotion.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
```

The resulting approval digest detects accidental changes; it is not a digital
signature and does not prove the approver's identity. Attach the approved plan
and staging evidence to the authoritative change record, where identity,
separation of duties, and audit retention are enforced.

## 5. Run the read-only production preflight

Select the reviewed production context deliberately, then run:

```powershell
kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\test-production-promotion-plan.ps1 `
  -PlanPath .\.shieldward\production\promotion.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Approved `
  -CheckCluster
```

The cluster preflight checks the current context exactly, passes that same
context explicitly to every read, confirms the namespace and expected Secret
names, and verifies that both live deployment images still match the approved
rollback baseline. It makes no cluster changes and never reads Secret values.

If the preflight reports drift, promotion is blocked. Reconcile the production
baseline through its owning system and create a new plan if any approved input
must change.

## 6. Promote a controlled cohort

Use the approved production platform or GitOps workflow to deploy the candidate
image references from the plan to the smallest supported cohort. Confirm the
actual traffic controller limits exposure; the local plan records intent but
does not enforce traffic routing.

During the full observation window, monitor readiness, error outcomes, policy
age, rejected reloads, rate-limit dependency health, circuit transitions,
resource saturation, and drain behavior. Exercise certificate-validated
health, default-deny, and protected-route probes without sending
non-idempotent business requests.

Expand traffic only while every environment-specific acceptance check remains
inside its approved error budget. Record each cohort size, decision time,
operator, observed metrics, and exact live image digests in the change record.

## 7. Stop or roll back

Any failed or missing check blocks expansion. Stop the production platform's
promotion workflow and restore both rollback image references from the plan.
Restore policy, credentials, or Redis state through their owning systems when
those inputs also changed.

After rollback, wait for both deployments, repeat the target-environment probes,
and run the read-only cluster preflight again. It passes only when the live
deployments match the approved rollback digests. Preserve the failure evidence
and issue a new release rather than changing an immutable tag.
