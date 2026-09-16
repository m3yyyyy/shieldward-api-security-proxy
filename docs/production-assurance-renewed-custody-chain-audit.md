# Renewed production assurance custody chain audit

Use this runbook after at least one recurring renewed custody review has
passed. Chapter 64 inventories the complete post-renewal chain from the
Chapter 61 baseline sequence through the selected Chapter 63 head while
preserving the original custody identity and pre-renewal chain digest.

This repository does not schedule reviews, inspect or alter archives, renew
retention, change access, perform restores, delete evidence, or change
production. External systems remain authoritative.

## 1. Preserve the renewed audit boundary

A passed renewed custody chain audit requires all of these conditions:

- the head is an exact passed recurring renewed custody review;
- every predecessor remains present beneath ignored `.shieldward` state;
- the first entry is the exact Chapter 62 review at the Chapter 61 baseline's
  next sequence;
- every path, hash, integrity digest, link digest, sequence, and deadline
  matches with no gap or cycle;
- the baseline, Chapter 60 renewal evidence, original custody record, and
  pre-renewal chain digest remain unchanged across every entry;
- the current head gate and independent governance review pass;
- the authoritative renewed-chain inventory is complete;
- retention, access, and isolated restore audits pass; and
- the next review remains inside renewed retention.

The collector derives the sequence range, entries, count, and aggregate
digest. Operators cannot declare those values. Unknown states fail closed,
and registration is not enforcement.

## 2. Test the local contract

~~~powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-renewed-custody-chain-audit-contract.ps1
~~~

Its final line must be:

~~~text
Renewed production assurance custody chain-audit contract passed.
~~~

The contract uses only ignored `.shieldward` data. It verifies two-entry and
three-entry renewed chains and rejects incomplete, missing, changed, at-risk,
failed, unknown, stale, wrong-context, non-recurring-head, and tampered cases.

## 3. Select the exact renewed chain head

~~~powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$renewalPlanFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-plan' -Filter 'retention-renewal-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewalEvidenceFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-retention-renewal-evidence' -Filter 'retention-renewal-evidence-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$renewedBaselineFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-baseline' -Filter 'renewed-custody-baseline-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$chainHeadFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-recurring' -Filter 'renewed-custody-review-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if ($null -eq $renewalPlanFile -or $null -eq $renewalEvidenceFile -or $null -eq $renewedBaselineFile -or $null -eq $chainHeadFile) {
  throw 'The plan, renewal evidence, baseline, and recurring renewed head are required.'
}

$headGateArguments = @{
  EvidencePath = $chainHeadFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  MaxEvidenceAgeMinutes = 60
}
& .\scripts\test-production-assurance-renewed-custody-recurring-gate.ps1 @headGateArguments
~~~

Never edit generated JSON. The audit follows exact predecessor paths from the
head and rejects a missing, changed, cyclic, or discontinuous chain.

## 4. Gather authoritative audit references

~~~powershell
$chainHeadGateReference = 'REPLACE_WITH_GREEN_RENEWED_HEAD_GATE'
$renewedChainInventoryReference = 'REPLACE_WITH_COMPLETE_RENEWED_CHAIN_INVENTORY'
$baselineReference = 'REPLACE_WITH_RENEWED_BASELINE_CONFIRMATION'
$renewalEvidenceReference = 'REPLACE_WITH_RENEWAL_EVIDENCE_CONFIRMATION'
$originalLineageReference = 'REPLACE_WITH_ORIGINAL_LINEAGE_CONFIRMATION'
$evidenceRetentionReference = 'REPLACE_WITH_RETENTION_CONTROL_PROOF'
$independentReviewReference = 'REPLACE_WITH_INDEPENDENT_GOVERNANCE_REVIEW'
$accessAuditReference = 'REPLACE_WITH_EVIDENCE_ACCESS_AUDIT'
$restoreAuditReference = 'REPLACE_WITH_ISOLATED_RESTORE_AUDIT'
$auditedBy = 'REPLACE_WITH_ACCOUNTABLE_AUDITOR'
~~~

Use authoritative non-secret identifiers or URLs without credentials, tokens,
secret query parameters, placeholders, or control characters.

## 5. Record the renewed chain audit

~~~powershell
$auditArguments = @{
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
  AuditCompletedAtUtc = [DateTimeOffset]::UtcNow
  ChainHeadGateStatus = 'passed'
  RenewedChainInventoryStatus = 'complete'
  BaselineStatus = 'verified'
  RenewalEvidenceStatus = 'verified'
  OriginalLineageStatus = 'preserved'
  EvidenceRetentionStatus = 'retained'
  IndependentReviewStatus = 'passed'
  AccessAuditStatus = 'passed'
  RestoreAuditStatus = 'passed'
  ChainHeadGateReference = $chainHeadGateReference
  RenewedChainInventoryReference = $renewedChainInventoryReference
  BaselineReference = $baselineReference
  RenewalEvidenceReference = $renewalEvidenceReference
  OriginalLineageReference = $originalLineageReference
  EvidenceRetentionReference = $evidenceRetentionReference
  IndependentReviewReference = $independentReviewReference
  AccessAuditReference = $accessAuditReference
  RestoreAuditReference = $restoreAuditReference
  AuditedBy = $auditedBy
  MaxHeadEvidenceAgeHours = 2208
  MaxAuditAgeMinutes = 60
}
& .\scripts\new-production-assurance-renewed-custody-chain-audit-evidence.ps1 @auditArguments
~~~

The immutable output is written beneath
`.shieldward/production-assurance-renewed-custody-chain-audit`.

## 6. Inspect and validate the audit

~~~powershell
$auditFile = Get-ChildItem -LiteralPath '.\.shieldward\production-assurance-renewed-custody-chain-audit' -Filter 'renewed-custody-chain-audit-*.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
Get-Content -LiteralPath $auditFile.FullName

$validationArguments = @{
  EvidencePath = $auditFile.FullName
  ChainHeadEvidencePath = $chainHeadFile.FullName
  BaselinePath = $renewedBaselineFile.FullName
  RenewalEvidencePath = $renewalEvidenceFile.FullName
  PlanPath = $renewalPlanFile.FullName
  ExpectedProductionContext = $productionContext
}
& .\scripts\test-production-assurance-renewed-custody-chain-audit-evidence.ps1 @validationArguments
~~~

Confirm the outcome is `passed`, every verification flag is true, the initial
sequence matches the baseline, the head and entry count agree, the next review
remains within retention, and the action is
`continue-renewed-custody-reviews`.

## 7. Apply the freshness gate

~~~powershell
$gateArguments = $validationArguments.Clone()
$gateArguments.MaxEvidenceAgeMinutes = 60
& .\scripts\test-production-assurance-renewed-custody-chain-audit-gate.ps1 @gateArguments
~~~

A green gate proves only the recorded audit checkpoint. It does not schedule
reviews, enforce retention, alter archives, change access, restore data,
delete evidence, or modify production.

## 8. Continue without resetting the chain

Continue
[recurring renewed custody reviews](production-assurance-renewed-custody-recurring.md)
at the exact head's next recorded deadline. Preserve the audit, baseline,
renewal evidence, original custody record, pre-renewal chain, and every renewed
review. Failed or unknown evidence cannot authorize continuation; follow its
recorded action and keep the complete chain intact.

When the recorded action is `renew-retention-before-continuing`, stop and use
the [renewed retention-renewal plan](production-assurance-renewed-retention-renewal.md).
Its approval does not prove execution or permit the chain to resume.
