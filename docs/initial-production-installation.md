# Initial production installation gate

Use this gate only when ShieldWard has never had a verified production release
in the target context. It covers the special case where no older image digests
exist for rollback. The safe fallback is removal back to an absent installation,
not an invented previous release.

This is an operator decision gate. It does not deploy workloads, create or read
credentials, change a cluster, or enforce traffic routing. The approved
production platform or GitOps workflow remains responsible for installation,
external traffic isolation, removal, and audit retention.

After the first release becomes a verified production baseline, use
`docs/production-promotion.md` for every later release.

## 1. Required inputs

Before creating a plan, record:

1. the sanitized staging evidence from a digest-pinned rollout with the
   control-plane outage drill enabled;
2. an exact production Kubernetes context that differs from staging;
3. a change-record identifier and approval owner;
4. the owner of the external traffic controller that will keep traffic disabled;
5. the authority and approved procedure reference for removing the installation
   back to an absent state; and
6. an observation window between 5 minutes and 24 hours.

The removal procedure must be reviewed in the authoritative change system. A
free-form note is not proof that removal was tested. The local plan records the
reference but cannot verify the external system or the operator's identity.

## 2. Test the local contract

Run the self-contained contract before working with a real plan:

```powershell
pwsh -NoProfile -File .\scripts\test-initial-production-contract.ps1
```

Its final line must be:

```text
Initial production installation planning contract passed.
```

The contract uses synthetic evidence beneath the ignored `.shieldward`
directory. It makes no cluster changes.

## 3. Generate a pending plan

Run from the repository root and replace every example value. Do not use the
staging context as the production context.

```powershell
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'

pwsh -NoProfile -File .\scripts\new-initial-production-plan.ps1 `
  -StagingEvidencePath $stagingEvidence `
  -ProductionContext $productionContext `
  -ChangeId 'CHG-REPLACE' `
  -ApprovalOwner 'REPLACE APPROVAL OWNER' `
  -RemovalAuthority 'REPLACE REMOVAL AUTHORITY' `
  -TrafficController 'REPLACE EXTERNAL TRAFFIC CONTROLLER' `
  -RemovalProcedureReference 'REPLACE APPROVED PROCEDURE REFERENCE' `
  -ObservationMinutes 15
```

The generator verifies the staging release metadata, immutable candidate image
references, runtime versions, full deployment availability, policy continuity,
default-deny behavior, protected-route denial, outage behavior, and recovery.

The output is `.shieldward/production-initial/installation.json`. Its integrity
digest binds the candidate and staging evidence to the production context,
change record, traffic-disabled state, removal path, owners, and observation
window. It contains no credentials.

## 4. Review and validate before approval

```powershell
Get-Content .\.shieldward\production-initial\installation.json

pwsh -NoProfile -File .\scripts\test-initial-production-plan.ps1 `
  -PlanPath .\.shieldward\production-initial\installation.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending
```

Changing the evidence or any integrity-covered field blocks validation. Create
a new plan rather than hand-editing the JSON.

## 5. Record explicit approval

Copy the exact statement printed by the generator. It deliberately includes
`WITH TRAFFIC DISABLED`:

```powershell
pwsh -NoProfile -File .\scripts\approve-initial-production-plan.ps1 `
  -PlanPath .\.shieldward\production-initial\installation.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy 'REPLACE APPROVAL OWNER' `
  -ApprovalStatement 'APPROVE INITIAL INSTALL CHG-REPLACE FOR REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT WITH TRAFFIC DISABLED'
```

Attach the approved plan and staging evidence to the authoritative change
record. The local approval digest detects accidental modification; it is not a
digital signature.

## 6. Run the read-only empty-baseline preflight

Select the reviewed context deliberately, then run:

```powershell
kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\test-initial-production-plan.ps1 `
  -PlanPath .\.shieldward\production-initial\installation.json `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -RequiredState Approved `
  -CheckCluster
```

The preflight checks the current context exactly and passes that context to
every cluster read. The `shieldward` namespace may be absent or reserved for
pre-provisioned configuration, but no labeled ShieldWard workload, pod,
service, or ingress may exist. Secret values are never read.

Existing resources mean this is not an empty initial baseline. Stop and use the
normal promotion or recovery process instead.

## 7. Install with traffic disabled

Use only the approved platform or GitOps workflow. Apply the two digest-pinned
candidate images from the plan while the external traffic controller remains
disabled. The committed Kubernetes base exposes only internal `ClusterIP`
services; do not add an Ingress, Gateway route, `NodePort`, or `LoadBalancer`
during this phase.

From an approved internal probe location, verify TLS identity, health,
readiness, runtime version, policy digest, default deny, protected-route denial,
real identity-provider behavior, and a safe idempotent upstream request. Observe
availability, rejected reloads, error outcomes, rate-limit dependency health,
circuit transitions, resource saturation, and draining for the full window.

## 8. Establish the first rollback baseline

Only after every acceptance check passes, record the exact live control-plane
and Edge image digests, policy digest, timestamps, operators, and results in the
authoritative change record. Those live digests become the verified production
rollback baseline for the next release.

Enabling production traffic is a separate approved change. Revalidate the live
digests and traffic-controller state immediately before that change. Use
`docs/production-baseline-and-traffic.md` to collect the traffic-disabled
baseline and create a separately approved initial canary. This local gate does
not authorize or perform traffic enablement.

## 9. Abort or remove

If any check fails or evidence is missing, keep traffic disabled. Invoke the
approved removal procedure through its owning platform and return to the absent
target state. Do not automatically delete namespaces, secrets, certificates,
policy sources, or audit evidence; their retention and destruction are governed
by their owning security and incident procedures.

After removal, rerun the read-only empty-baseline preflight and preserve the
failure evidence. Fix the cause and issue a reviewed release rather than
changing an immutable tag.
