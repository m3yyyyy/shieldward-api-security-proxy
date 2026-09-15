# Production assurance retention-renewal plan

Use this runbook only when a validated custody chain audit reports missing
retention evidence and records `renew-retention-before-continuing`. Chapter 59
creates and independently approves a tamper-evident plan for the external
retention-renewal procedure.

This repository does not renew object lock, copy archive objects, change an
archive policy, perform a restore, delete evidence, or change production. The
external archive and change systems remain authoritative. Approval of this
local plan is not proof that retention was renewed.

## 1. Preserve the renewal boundary

A valid plan requires all of these conditions:

- the exact trigger is a failed custody chain audit whose only recorded action
  is retention renewal;
- the trigger still proves a contiguous review chain and unchanged root
  custody identity;
- the current root retention boundary has not expired;
- the requested date extends the existing boundary by the approved minimum;
- the requested date covers the next custody review by the required minimum;
- the archive location, renewal method, custody owner, restore authority, and
  independent approval owner are explicit;
- the approval identity and statement match exactly; and
- the plan, trigger hash, approval, and renewal dates remain tamper-evident.

The plan cannot shorten retention, reset the custody-review sequence, replace
the root custody checksum, or declare external execution successful.
Registration is not enforcement.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-contract.ps1
```

Its final line must be:

```text
Production assurance retention-renewal planning contract passed.
```

The test uses only ignored `.shieldward` data. It covers pending and approved
states, an invalid trigger, an inadequate extension, incorrect approval,
staleness, and plan or trigger tampering. It never contacts an archive.

## 3. Select the exact failed custody audit

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$triggerEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-chain-audit' `
  -Filter 'custody-chain-audit-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $triggerEvidenceFile) {
  throw 'Custody chain-audit trigger evidence was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-chain-audit-evidence.ps1 `
  -EvidencePath $triggerEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Inspect the JSON. It must report `outcome: failed`,
`evidenceRetentionStatus: missing`, and
`nextAction: renew-retention-before-continuing`. Never edit generated JSON.

## 4. Create the pending plan

Use the requested date and identifiers from the approved external change
record. Do not include credentials, access tokens, or secret query parameters.

```powershell
$changeId = 'REPLACE_WITH_CHANGE_ID'
$requestedRetentionUntilUtc = [DateTimeOffset]'REPLACE_WITH_UTC_RETENTION_DATE'
$archiveLocationReference = 'REPLACE_WITH_IMMUTABLE_ARCHIVE_REFERENCE'
$approvalOwner = 'REPLACE_WITH_INDEPENDENT_APPROVER'
$custodyOwner = 'REPLACE_WITH_CUSTODY_OWNER'
$restoreAuthority = 'REPLACE_WITH_RESTORE_AUTHORITY'

pwsh -NoProfile -File .\scripts\new-production-assurance-retention-renewal-plan.ps1 `
  -TriggerEvidencePath $triggerEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ChangeId $changeId `
  -RequestedRetentionUntilUtc $requestedRetentionUntilUtc `
  -RenewalMethod extend-existing-object-lock `
  -ArchiveLocationReference $archiveLocationReference `
  -ApprovalOwner $approvalOwner `
  -CustodyOwner $custodyOwner `
  -RestoreAuthority $restoreAuthority `
  -MinimumExtensionDays 365 `
  -MinimumRemainingDaysAfterNextReview 180
```

Use `copy-to-new-immutable-generation` only when the approved external design
requires a new immutable generation. The repository performs neither method.

## 5. Inspect and validate the pending plan

```powershell
$renewalPlanFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-retention-renewal-plan' `
  -Filter 'retention-renewal-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $renewalPlanFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-plan.ps1 `
  -PlanPath $renewalPlanFile.FullName `
  -TriggerEvidencePath $triggerEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -RequiredState Pending
```

Confirm the trigger checksum, root custody and review-chain digests, current
retention, requested retention, next review, authorities, and approval
statement match the authoritative change record.

## 6. Record independent approval

Copy `approval.requiredStatement` exactly from the inspected plan.

```powershell
$approvalStatement = 'REPLACE_WITH_EXACT_REQUIRED_STATEMENT'

pwsh -NoProfile -File .\scripts\approve-production-assurance-retention-renewal-plan.ps1 `
  -PlanPath $renewalPlanFile.FullName `
  -TriggerEvidencePath $triggerEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -ApprovedBy $approvalOwner `
  -ApprovalStatement $approvalStatement
```

The approval is a local audit record. It does not change the archive and does
not replace the authoritative external approval.

## 7. Apply the approval and freshness gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-retention-renewal-gate.ps1 `
  -PlanPath $renewalPlanFile.FullName `
  -TriggerEvidencePath $triggerEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxPlanAgeMinutes 60
```

A green gate authorizes only the exact recorded external procedure. It does
not prove that retention was renewed. If the plan is stale, the current
retention expires, or any input changes, stop and create a new approved plan.

## 8. Execute externally and preserve evidence

The custody owner performs the approved method in the authoritative archive
system. Preserve the external change result, new immutable retention proof,
object-lock state, complete inventory, access review, and independent restore
verification. Do not resume custody reviews or report renewed retention until
that execution has separate validated evidence.
