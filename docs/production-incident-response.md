# Production incident response planning

Use this procedure when a current continuous production assurance snapshot has
an outcome of `failed` or `unknown`. It converts that immutable snapshot into a
tamper-evident response plan with an explicit incident, change, action,
authority, deadline, and approval record.

The repository scripts are planning and validation tools. They do not change
Kubernetes, route traffic, rotate certificates, roll back workloads, or update
an external incident system. Production execution remains the responsibility
of the authoritative traffic, deployment, identity, and incident platforms.
The generated plan never executes a production change.

## 1. Preserve the triggering evidence

Do not overwrite or delete the failed assurance snapshot. Attach it to the
authoritative incident record and establish all of the following:

1. the exact production context and immutable candidate;
2. the incident identifier and associated change identifier;
3. the recorded rollback authority and procedure;
4. the owner of the external traffic controller; and
5. a response deadline appropriate to the incident severity.

Unknown or missing information fails closed. Collect a current assurance
snapshot if the triggering record is too old to support a response decision.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-response-contract.ps1
```

Its final line must be:

```text
Production incident response planning contract passed.
```

The test uses only synthetic files beneath `.shieldward`. It never contacts or
changes production.

## 3. Select one explicit response

Use the assurance snapshot's `decision.requiredAction` to choose the response:

| Assurance action | Allowed response |
| --- | --- |
| `reaccept-before-continuing` | `reaccept-before-continuing` |
| `disable-and-investigate` | `disable-and-investigate` |
| `rotate-certificates-and-refresh-evidence` | `rotate-certificates-and-refresh-evidence` |
| `rollback-or-disable-and-investigate` | `rollback-to-75-and-investigate` or `disable-and-investigate` |
| `investigate-and-refresh-evidence` | `investigate-and-refresh-evidence` or `disable-and-investigate` |

The only branch requiring an operator choice is the general health-failure
case. Use the recorded 75 percent cohort only when candidate correctness and
security remain intact. Use zero traffic for security, identity, correctness,
invalid-certificate, or unresolved unknown-state risk.

## 4. Create the pending plan

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$assuranceFile = '.shieldward/production-assurance/assurance-REPLACE_TIMESTAMP.json'
$assurance = Get-Content -Raw -LiteralPath $assuranceFile | ConvertFrom-Json
$responseOwner = [string]$assurance.rollback.authority

pwsh -NoProfile -File .\scripts\new-production-incident-response-plan.ps1 `
  -AssuranceEvidencePath $assuranceFile `
  -ExpectedProductionContext $productionContext `
  -IncidentId 'INC-REPLACE' `
  -ChangeId 'CHG-REPLACE' `
  -ResponseOwner $responseOwner `
  -ResponseAction 'REPLACE_WITH_ALLOWED_ACTION' `
  -ResponseDeadlineMinutes 15 `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The output is `.shieldward/production-incident-response/response.json`. The
plan binds the source evidence hash and integrity digest, exact candidate,
current and target traffic percentages, response authority, deadline, rollback
boundary, and required approval statement.

`-CheckCluster` performs read-only exact-context verification through the
linked assurance chain. It does not read Secret values or mutate workloads.

## 5. Inspect and validate the pending plan

```powershell
Get-Content .\.shieldward\production-incident-response\response.json

pwsh -NoProfile -File .\scripts\test-production-incident-response-plan.ps1 `
  -PlanPath .\.shieldward\production-incident-response\response.json `
  -AssuranceEvidencePath $assuranceFile `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Stop if the plan is expired, the evidence changed, the action is inconsistent,
the context is wrong, or any linked record fails validation. Generate a new
plan from current evidence rather than editing JSON.

## 6. Record explicit approval

Copy `approval.requiredStatement` exactly from the inspected plan. The approver
must exactly match the response authority recorded in the accepted rollback
chain.

```powershell
$responsePlan = Get-Content -Raw `
  .\.shieldward\production-incident-response\response.json | ConvertFrom-Json

pwsh -NoProfile -File .\scripts\approve-production-incident-response-plan.ps1 `
  -PlanPath .\.shieldward\production-incident-response\response.json `
  -AssuranceEvidencePath $assuranceFile `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy ([string]$responsePlan.approval.owner) `
  -ApprovalStatement ([string]$responsePlan.approval.requiredStatement) `
  -CheckCluster
```

Approval writes a tamper-detecting local audit record. It is not traffic or
deployment authorization by itself; the external incident and change systems
remain authoritative.

## 7. Execute through the authoritative platform

Attach the approved plan to the incident and change records, revalidate it, and
then perform the recorded action through the owning platform. Keep these
boundaries:

- `disable-and-investigate` targets externally enforced zero traffic;
- `rollback-to-75-and-investigate` restores only the recorded 75 percent
  cohort and is not valid for security or correctness uncertainty;
- certificate rotation follows the approved identity procedure and preserves
  the last-known-good trust boundary;
- re-acceptance freezes further change until the applicable rollout chain is
  repeated; and
- investigation never converts missing evidence into a healthy state.

Preserve command output, platform audit events, traffic confirmation, workload
digests, and incident timestamps outside the repository.

Then follow `docs/production-incident-containment.md` to bind those records to
the approved plan and prove the exact response boundary. Do not begin recovery
from approval or command output alone.

## 8. Recover and close

After containment or remediation, collect a new assurance snapshot. Material
image, policy, configuration, identity, or routing drift requires the
applicable production acceptance path before full traffic can continue. Close
the incident only after current evidence passes, the external controller state
is confirmed, and the authoritative incident owner records the outcome.
