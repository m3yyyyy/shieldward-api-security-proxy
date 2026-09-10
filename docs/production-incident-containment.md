# Production incident containment evidence

Use this procedure after an explicitly approved plan from
`docs/production-incident-response.md` has been executed through the owning
external platform. It records whether the response actually reached its exact
100, 75, or 0 percent traffic boundary and whether workloads, execution, and
the authoritative incident record were verified.

These repository scripts collect and validate references supplied by the
operator. They never route traffic, change workloads, rotate certificates, or
update an incident system. A plan proves approval; only current containment
evidence proves that the approved response happened.

## 1. Preserve the external execution record

Before collecting evidence, preserve all of the following in the authoritative
incident and change systems:

1. the approved response plan and exact approval digest;
2. the UTC execution timestamp and platform audit event;
3. the external traffic-controller state;
4. workload or certificate verification appropriate to the response; and
5. the incident owner acknowledgement.

Do not infer success from a command returning without error. Missing, unknown,
late, mismatched, or tampered evidence fails closed.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-containment-contract.ps1
```

Its final line must be:

```text
Production incident containment evidence contract passed.
```

The test creates only synthetic artifacts under `.shieldward`. It proves the
hold-at-100, rollback-to-75, and disable-to-zero boundaries without contacting
production.

## 3. Confirm the expected boundary

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$responsePlanPath = '.shieldward/production-incident-response/response.json'
$responsePlan = Get-Content -Raw -LiteralPath $responsePlanPath | ConvertFrom-Json

$responsePlan.response.action
$responsePlan.traffic.targetPercent
$responsePlan.response.deadlineAtUtc
```

The exact mappings are:

| Approved response | Required observed traffic |
| --- | ---: |
| `reaccept-before-continuing` | 100% |
| `investigate-and-refresh-evidence` | 100% |
| `rotate-certificates-and-refresh-evidence` | 100% |
| `rollback-to-75-and-investigate` | 75% |
| `disable-and-investigate` | 0% |

Any other observed percentage is a failed containment result, not a partial
success.

## 4. Collect current containment evidence

Use the actual UTC time from the external execution record. Every reference
must identify durable evidence in the owning system.

```powershell
$executedAtUtc = [DateTimeOffset]'REPLACE_WITH_EXECUTION_UTC_TIMESTAMP'
$observedTrafficPercent = [int]$responsePlan.traffic.targetPercent

pwsh -NoProfile -File .\scripts\new-production-incident-containment-evidence.ps1 `
  -PlanPath $responsePlanPath `
  -ExpectedProductionContext $productionContext `
  -ExecutedAtUtc $executedAtUtc `
  -ObservedTrafficPercent $observedTrafficPercent `
  -TrafficEnforcementStatus confirmed `
  -WorkloadVerificationStatus confirmed `
  -ResponseExecutionStatus completed `
  -IncidentRecordStatus updated `
  -TrafficStateReference 'REPLACE TRAFFIC AUDIT REFERENCE' `
  -WorkloadEvidenceReference 'REPLACE WORKLOAD EVIDENCE REFERENCE' `
  -ResponseExecutionReference 'REPLACE EXECUTION AUDIT REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -CollectedBy 'REPLACE REVIEWER' `
  -MaxExecutionAgeMinutes 60 `
  -CheckCluster
```

The output is a timestamped file beneath
`.shieldward/production-incident-containment`. The collector binds the approved
plan hash, integrity and approval digests, execution deadline, exact response
action, traffic state, verification statuses, and external references.

Record `failed`, `missing`, or `unknown` honestly. The collector preserves the
failed result and the gate blocks it. Never edit the timestamp to make a late
response appear timely.

## 5. Inspect and validate the evidence

```powershell
$containmentFile = Get-ChildItem `
  .\.shieldward\production-incident-containment\containment-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $containmentFile.FullName

pwsh -NoProfile -File .\scripts\test-production-incident-containment-evidence.ps1 `
  -EvidencePath $containmentFile.FullName `
  -PlanPath $responsePlanPath `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

The validator recomputes the outcome and integrity digest and revalidates the
complete approved response chain. A changed plan, approval, candidate,
deadline, action, traffic boundary, or evidence reference is rejected.

## 6. Apply the freshness-bound containment gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-containment-gate.ps1 `
  -EvidencePath $containmentFile.FullName `
  -PlanPath $responsePlanPath `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The gate requires a completed response before its deadline, exact externally
enforced traffic, confirmed workloads, an updated incident record, a passed
outcome, and current evidence. It is read-only and does not authorize recovery
or traffic restoration.

## 7. Follow the recorded next action

- A re-acceptance response remains frozen until the applicable production
  rollout acceptance chain passes again.
- A zero-traffic response remains at zero until remediation and an explicitly
  approved recovery gate permit restoration.
- A 75 percent rollback remains bounded to that cohort while remediation and
  recovery evidence are prepared.
- Certificate rotation and investigation responses require a new production
  assurance snapshot.
- Failed or unknown containment requires immediate escalation and new current
  evidence; never continue from the failed artifact.

Attach the immutable containment file and gate output to the authoritative
incident record. Preserve all failed attempts as audit evidence.
