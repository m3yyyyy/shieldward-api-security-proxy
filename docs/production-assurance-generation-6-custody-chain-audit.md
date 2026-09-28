# Generation-6 production assurance custody chain audit

Use this runbook after at least one recurring generation-6 custody review has
passed. Chapter 88 inventories the complete generation-6 chain from the
Chapter 85 baseline sequence through the selected Chapter 87 head while
preserving all five renewal generations, the original custody identity, and every
earlier review-chain digest.

This repository does not schedule reviews, inspect or alter archives, renew
retention, change access, perform restores, delete evidence, or change
production. External systems remain authoritative.

## 1. Preserve the generation-6 audit boundary

A passed generation-6 custody chain audit requires all of these conditions:

- the head is an exact passed recurring generation-6 custody review;
- every predecessor remains present beneath ignored `.shieldward` state;
- the first entry is the exact Chapter 86 review at the Chapter 85 baseline's
  next sequence;
- every path, hash, integrity digest, link digest, sequence, and deadline
  matches with no gap or cycle;
- the generation-6 baseline, Chapter 84 renewal evidence, all inherited
  renewal generations, original custody record, and earlier review-chain digests
  remain unchanged across every entry;
- the current head gate and independent governance review pass;
- the authoritative generation-6 chain inventory is complete;
- retention, access, and isolated restore audits pass; and
- the next review remains inside renewed retention.

The collector derives the sequence range, entries, count, and aggregate
digest. Operators cannot declare those values. Unknown states fail closed,
and registration is not enforcement.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-generation-6-custody-chain-audit-contract.ps1
~~~

Its final line must be:

~~~text
Generation-6 production assurance custody chain-audit contract passed.
~~~

The contract uses only ignored `.shieldward` data. It verifies two-entry and
three-entry generation-6 chains and rejects incomplete, missing, changed, at-risk,
failed, unknown, stale, wrong-context, non-recurring-head, and tampered cases.

## 3. Select the exact generation-6 chain head

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-plan' -Filter 'generation-5-retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-5-retention-renewal-evidence' -Filter 'generation-5-retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$generation6BaselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-baseline' -Filter 'generation-6-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$chainHeadFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-recurring' -Filter 'generation-6-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $renewalPlanFile -or $null -eq $renewalEvidenceFile -or $null -eq $generation6BaselineFile -or $null -eq $chainHeadFile) {
  throw 'The plan, renewal evidence, baseline, and recurring generation-6 head are required.'
}

$headGateArguments = @{
  EvidencePath = $chainHeadFile.FullName
  BaselinePath = $generation6BaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  MaxEvidenceAgeMinutes = 60
}
& .\scripts\test-production-assurance-generation-6-custody-recurring-gate.ps1 @headGateArguments
~~~

Never edit generated JSON. The audit follows exact predecessor paths from the
head and rejects a missing, changed, cyclic, or discontinuous chain.

## 4. Gather authoritative audit references

~~~powershell
$chainHeadGateReference = 'REPLACE_WITH_GREEN_GENERATION_6_HEAD_GATE'
$generation6ChainInventoryReference = 'REPLACE_WITH_COMPLETE_GENERATION_6_CHAIN_INVENTORY'
$baselineReference = 'REPLACE_WITH_GENERATION_6_BASELINE_CONFIRMATION'
$renewalEvidenceReference = 'REPLACE_WITH_RENEWAL_EVIDENCE_CONFIRMATION'
$inheritedLineageReference = 'REPLACE_WITH_ORIGINAL_LINEAGE_CONFIRMATION'
$evidenceRetentionReference = 'REPLACE_WITH_RETENTION_CONTROL_PROOF'
$independentReviewReference = 'REPLACE_WITH_INDEPENDENT_GOVERNANCE_REVIEW'
$accessAuditReference = 'REPLACE_WITH_EVIDENCE_ACCESS_AUDIT'
$restoreAuditReference = 'REPLACE_WITH_ISOLATED_RESTORE_AUDIT'
$auditedBy = 'REPLACE_WITH_ACCOUNTABLE_AUDITOR'
~~~

Use authoritative non-secret identifiers or URLs without credentials, tokens,
secret query parameters, placeholders, or control characters.

## 5. Record the generation-6 chain audit

~~~powershell
$auditArguments = @{
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $generation6BaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  AuditCompletedAtUtc = [DateTimeOffset]::UtcNow
  ChainHeadGateStatus = 'passed'
  Generation6ChainInventoryStatus = 'complete'
  BaselineStatus = 'verified'
  RenewalEvidenceStatus = 'verified'
  InheritedLineageStatus = 'preserved'
  EvidenceRetentionStatus = 'retained'
  IndependentReviewStatus = 'passed'
  AccessAuditStatus = 'passed'
  RestoreAuditStatus = 'passed'
  ChainHeadGateReference = $chainHeadGateReference
  Generation6ChainInventoryReference = $generation6ChainInventoryReference
  BaselineReference = $baselineReference
  RenewalEvidenceReference = $renewalEvidenceReference
  InheritedLineageReference = $inheritedLineageReference
  EvidenceRetentionReference = $evidenceRetentionReference
  IndependentReviewReference = $independentReviewReference
  AccessAuditReference = $accessAuditReference
  RestoreAuditReference = $restoreAuditReference
  AuditedBy = $auditedBy
  MaxHeadEvidenceAgeHours = 2208
  MaxAuditAgeMinutes = 60
}
& .\scripts\new-production-assurance-generation-6-custody-chain-audit-evidence.ps1 @auditArguments
~~~

The immutable output is written beneath
`.shieldward/production-assurance-generation-6-custody-chain-audit`.

## 6. Inspect and validate the audit

~~~powershell
$auditFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-generation-6-custody-chain-audit' -Filter 'generation-6-custody-chain-audit-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
Get-Content -LiteralPath $auditFile.FullName

$validationArguments = @{
  EvidencePath = $auditFile.FullName
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $generation6BaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-generation-6-custody-chain-audit-evidence.ps1 @validationArguments
~~~

Confirm the outcome is `passed`, every verification flag is true, the initial
sequence matches the baseline, the head and entry count agree, the next review
remains within retention, and the action is
`continue-generation-6-custody-reviews`.

## 7. Apply the freshness gate

~~~powershell
$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-generation-6-custody-chain-audit-gate.ps1 @gateArguments
~~~

A green gate proves only the recorded audit checkpoint. It does not schedule
reviews, enforce retention, alter archives, change access, restore data,
delete evidence, or modify production.

## 8. Continue without resetting the chain

Continue
[recurring generation-6 custody reviews](production-assurance-generation-6-custody-recurring.md)
at the exact head's next recorded deadline. Preserve the audit, baseline,
renewal evidence, original custody record, pre-renewal chain, and every generation-6
review. Failed or unknown evidence cannot authorize continuation; follow its
recorded action and keep the complete chain intact.

When the recorded action is `renew-retention-before-continuing`, stop and use
the [generation-6 retention-renewal plan](production-assurance-generation-6-retention-renewal.md).
Its approval does not prove execution or permit the chain to resume.
