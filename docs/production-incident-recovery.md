# Production incident recovery planning

Use this procedure only after `docs/production-incident-containment.md` has
produced passed, tamper-evident containment evidence. Recovery is a separate
change: containment approval and successful command output do not authorize
traffic restoration.

These scripts create, validate, and approve a read-only recovery record. They
never route traffic, change workloads, close an incident, or prove that the
approved restoration happened.

## 1. Preserve recovery prerequisites

Before creating a plan, record all of the following in the authoritative
incident and change systems:

1. the immutable passed containment artifact;
2. the current externally enforced traffic boundary;
3. completed remediation, or an explicit record that it was not required;
4. any mandatory production re-acceptance result;
5. current functional, dependency, operational, capacity, security, drift,
   and certificate evidence;
6. an updated incident record; and
7. a separately approved recovery change record.

Unknown, pending, missing, degraded, failed, or tampered prerequisites fail
closed. The generated record remains blocked and cannot be approved.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-contract.ps1
```

Its final line must be:

```text
Production incident recovery planning contract passed.
```

The test uses only synthetic files under `.shieldward`. It proves the 0% to
1-10% canary, 75% to 100%, and 100% hold-resumption paths. It also proves that
invalid targets, failed remediation, missing re-acceptance, unknown traffic,
pending external changes, inexact approval, and tampering remain blocked.

## 3. Select the exact recovery boundary

Find the current containment artifact:

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$containmentFile = Get-ChildItem `
  .\.shieldward\production-incident-containment\containment-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1
$containment = Get-Content -Raw -LiteralPath $containmentFile.FullName |
  ConvertFrom-Json

$containment.incidentId
$containment.changeId
$containment.traffic.observedPercent
$containment.decision.nextAction
```

The exact recovery mappings are:

| Contained traffic | Allowed recovery target | Mode |
| ---: | ---: | --- |
| 0% | 1-10% | bounded canary restoration |
| 75% | 100% | restore full traffic |
| 100% | 100% | resume only after required re-acceptance |

Zero traffic never jumps directly to 25%, 75%, or 100%. The previous contained
boundary remains the rollback target, and zero remains the emergency target.

## 4. Create the recovery plan

Use a recovery change identifier that is different from the containment
change. Set `RemediationStatus` or `ReacceptanceStatus` to `not-required` only
when the passed containment decision truly does not require that step.

```powershell
$recoveryChangeId = 'REPLACE_WITH_SEPARATE_RECOVERY_CHANGE_ID'
$recoveryOwner = 'REPLACE_WITH_RECORDED_RESPONSE_AUTHORITY'
$targetTrafficPercent = switch ([int]$containment.traffic.observedPercent) {
  0 { 1 }
  75 { 100 }
  100 { 100 }
  default { throw 'Unsupported containment boundary.' }
}

pwsh -NoProfile -File .\scripts\new-production-incident-recovery-plan.ps1 `
  -ContainmentEvidencePath $containmentFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RecoveryChangeId $recoveryChangeId `
  -RecoveryOwner $recoveryOwner `
  -TargetTrafficPercent $targetTrafficPercent `
  -CurrentTrafficStatus confirmed `
  -RemediationStatus completed `
  -ReacceptanceStatus passed `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear `
  -DriftStatus clear `
  -CertificateStatus healthy `
  -IncidentRecordStatus updated `
  -RecoveryChangeStatus approved `
  -TrafficStateReference 'REPLACE TRAFFIC AUDIT REFERENCE' `
  -RemediationEvidenceReference 'REPLACE REMEDIATION REFERENCE' `
  -ReacceptanceEvidenceReference 'REPLACE REACCEPTANCE REFERENCE' `
  -RecoveryVerificationReference 'REPLACE RECOVERY VERIFICATION REFERENCE' `
  -IncidentRecordReference 'REPLACE INCIDENT RECORD REFERENCE' `
  -RecoveryChangeReference 'REPLACE RECOVERY CHANGE REFERENCE' `
  -ReviewedBy 'REPLACE RECOVERY REVIEWER' `
  -ApprovalWindowMinutes 15 `
  -MaxContainmentAgeMinutes 10080 `
  -CheckCluster
```

The output is
`.shieldward/production-incident-recovery/recovery.json`. A passed readiness
result creates a pending plan. Failed or unknown readiness creates a blocked
plan that preserves the evidence but cannot be approved.

## 5. Inspect and validate

```powershell
$recoveryPlanPath = '.shieldward/production-incident-recovery/recovery.json'
Get-Content -LiteralPath $recoveryPlanPath

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-plan.ps1 `
  -PlanPath $recoveryPlanPath `
  -ContainmentEvidencePath $containmentFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending `
  -CheckCluster
```

Confirm the candidate digests, incident and recovery change identifiers,
current and target percentages, rollback boundary, readiness outcome, owner,
expiry, and every external reference.

## 6. Approve the exact recovery plan

Copy the generated `approval.requiredStatement` exactly after confirming that
the external recovery change is approved:

```powershell
$recoveryPlan = Get-Content -Raw -LiteralPath $recoveryPlanPath |
  ConvertFrom-Json
$approvalStatement = [string]$recoveryPlan.approval.requiredStatement

pwsh -NoProfile -File .\scripts\approve-production-incident-recovery-plan.ps1 `
  -PlanPath $recoveryPlanPath `
  -ContainmentEvidencePath $containmentFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy $recoveryOwner `
  -ApprovalStatement $approvalStatement `
  -CheckCluster
```

Approval is bound to the complete plan integrity digest and must occur before
the plan expires. It is a local audit record; the external incident, change,
and traffic systems remain authoritative.

## 7. Apply the final recovery gate

Run this immediately before the owning platform performs the recorded action:

```powershell
pwsh -NoProfile -File .\scripts\test-production-incident-recovery-gate.ps1 `
  -PlanPath $recoveryPlanPath `
  -ContainmentEvidencePath $containmentFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60 `
  -CheckCluster
```

The gate requires a current approved plan, passed readiness, confirmed current
traffic, healthy verification, cleared security and drift, the separately
approved recovery change, and any required remediation or re-acceptance.

## 8. Execute externally and preserve proof

Only the recorded recovery owner may use the authoritative traffic controller
to apply the exact target. If any prerequisite changes, the plan expires, or
the controller cannot enforce the target, hold or restore the contained
boundary and generate a new plan.

The gate does not prove restoration. Preserve the external execution event,
observed traffic, workload health, rollback readiness, and incident update as
separate post-execution evidence before declaring recovery complete.

Use `docs/production-incident-recovery-evidence.md` to create and validate that
post-execution record. Do not expand traffic, resume assurance, or close the
incident from this approved plan alone.
