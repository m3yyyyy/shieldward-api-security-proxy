# Generation-5 production assurance retention-renewal planning

Use this runbook only when an exact Chapter 82 generation-5 custody chain audit
fails because retention is at risk and records
`renew-retention-before-continuing`. Chapter 83 plans the next renewal without
resetting any inherited custody lineage.

This workflow creates and approves a local plan only. It does not change an
archive, object lock, retention, access, restore state, scheduler, cluster,
traffic, rollback, or production. External systems remain authoritative.

## 1. Preserve the renewal-generation boundary

An eligible plan must:

- bind the exact failed Chapter 82 audit and its recurring generation-5 head;
- preserve the Chapter 79 baseline, Chapter 78 renewal evidence, all four earlier
  renewals, original custody record, and every earlier review-chain digest;
- derive the next baseline generation and renewal sequence by adding one;
- extend the current unexpired retention boundary by the required minimum;
- cover the next recorded review with the required remaining retention;
- name the approval, custody, and restore authorities; and
- require an exact independent approval statement before external execution.

A passed audit, unrelated failure, unknown state, expired boundary, inadequate
extension, or changed lineage is not eligible. Approval authorizes only the recorded procedure and is not proof that retention changed.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-generation-5-retention-renewal-contract.ps1
~~~

Its final line must be:

~~~text
Generation-5 production assurance retention-renewal planning contract passed.
~~~

The contract uses ignored `.shieldward` data and covers derived generation,
exact approval, invalid trigger, inadequate extension, wrong context, stale
approval, and tampered plan and trigger evidence.

## 3. Select the exact trigger and lineage

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$triggerFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-custody-chain-audit' -Filter 'generation-5-custody-chain-audit-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$chainHeadFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-custody-recurring' -Filter 'generation-5-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$baselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-custody-baseline' -Filter 'generation-5-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-4-retention-renewal-evidence' -Filter 'generation-4-retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$previousRenewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-4-retention-renewal-plan' -Filter 'generation-4-retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $triggerFile -or $null -eq $chainHeadFile -or $null -eq $baselineFile -or $null -eq $renewalEvidenceFile -or $null -eq $previousRenewalPlanFile) {
  throw 'The generation-5 audit and its complete inherited renewal lineage are required.'
}
~~~

Never edit generated JSON or substitute a different audit, head, baseline,
renewal record, or prior approval.

## 4. Create the pending plan

Set authoritative non-secret identifiers and the requested boundary:

~~~powershell
$changeId = 'REPLACE_WITH_APPROVED_CHANGE_ID'
$requestedRetentionUntilUtc = [DateTimeOffset]'REPLACE_WITH_UTC_TIMESTAMP'

$newPlanArguments = @{
  TriggerEvidencePath = $triggerFile.FullName
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PreviousRenewalPlanPath = $previousRenewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  ChangeId = $changeId
  RequestedRetentionUntilUtc = $requestedRetentionUntilUtc
  RenewalMethod = 'extend-existing-object-lock'
  ArchiveLocationReference = 'REPLACE_WITH_ARCHIVE_LOCATION'
  ApprovalOwner = 'REPLACE_WITH_INDEPENDENT_APPROVER'
  CustodyOwner = 'REPLACE_WITH_CUSTODY_OWNER'
  RestoreAuthority = 'REPLACE_WITH_RESTORE_AUTHORITY'
  MinimumExtensionDays = 365
  MinimumRemainingDaysAfterNextReview = 180
}
& .\scripts\new-production-assurance-generation-5-retention-renewal-plan.ps1 @newPlanArguments
~~~

The pending plan is written beneath
`.shieldward/production-assurance-generation-5-retention-renewal-plan`. Inspect it
and copy its exact `approval.requiredStatement`.

## 5. Approve the exact boundary

~~~powershell
$planFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-plan' -Filter 'generation-5-retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$plan = Get-Content -Raw -LiteralPath $planFile.FullName | ConvertFrom-Json

$approvalArguments = @{
  PlanPath = $planFile.FullName
  TriggerEvidencePath = $triggerFile.FullName
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PreviousRenewalPlanPath = $previousRenewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  ApprovedBy = $plan.authorities.approvalOwner
  ApprovalStatement = $plan.approval.requiredStatement
}
& .\scripts\approve-production-assurance-generation-5-retention-renewal-plan.ps1 @approvalArguments
~~~

The approver and statement must match exactly. Never approve a plan merely
because it exists.

## 6. Apply the approval gate

~~~powershell
$gateArguments = @{
  PlanPath = $planFile.FullName
  TriggerEvidencePath = $triggerFile.FullName
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $baselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PreviousRenewalPlanPath = $previousRenewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  MaxPlanAgeMinutes = 60
}
& .\scripts\test-production-assurance-generation-5-retention-renewal-gate.ps1 @gateArguments
~~~

A green gate authorizes only the exact external procedure. Preserve the plan
and all bound evidence. Chapter 84 must record independent execution evidence
before any newer baseline or renewed review chain can be established. Follow
the [generation-5 retention-renewal evidence procedure](production-assurance-generation-5-retention-renewal-evidence.md)
and do not treat approval alone as proof of execution.
