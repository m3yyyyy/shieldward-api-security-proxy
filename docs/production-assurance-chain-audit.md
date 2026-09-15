# Production assurance chain audit evidence

Use this runbook after at least one recurring production assurance review has
passed. Chapter 53 links every scheduled review to its predecessor. This
chapter creates an immutable audit checkpoint that inventories the entire
retained chain from sequence 1 through the selected recurring head.

The audit is evidence-only. The repository intentionally provides no command
that schedules reviews, changes production, retains or deletes evidence, edits
incidents, or removes rollback. External operations and records systems remain
authoritative.

## 1. Preserve the audit boundary

A passed chain audit requires all of these conditions:

- the head is an exact passed recurring review at sequence 2 or later;
- every predecessor file remains present beneath the ignored state directory;
- hashes, integrity digests, candidate identity, and production context match;
- sequences are contiguous from 1 through the head with no gap or cycle;
- the derived entry count equals the head sequence;
- the current head gate is recorded as passed;
- the authoritative chain inventory is complete;
- retention evidence confirms every artifact is retained;
- independent review and evidence-access review both pass; and
- every external reference identifies current authoritative evidence.

The collector derives the chain entries, count, sequence range, and aggregate
digest. Operators cannot declare those values directly. A list of filenames
without hash and lineage validation is not a chain audit.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-chain-audit-contract.ps1
```

Its final line must be:

```text
Production assurance chain audit evidence contract passed.
```

The test uses only ignored `.shieldward` data. It verifies sequence-2 and
sequence-3 inventories, an invalid root-only head, failed external checks,
unknown state, stale evidence, and tampering with the audit, head, or interior
review.

## 3. Select and gate the recurring chain head

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$chainHeadEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-recurring' `
  -Filter 'review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $chainHeadEvidenceFile) {
  throw 'A recurring production assurance chain head was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-recurring-gate.ps1 `
  -EvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

Never edit generated JSON. The audit binds the exact head and every reachable
predecessor by path, SHA-256 hash, integrity digest, and sequence.

## 4. Gather authoritative audit references

```powershell
$chainHeadGateReference = 'REPLACE_WITH_GREEN_RECURRING_GATE_RUN'
$chainInventoryReference = 'REPLACE_WITH_COMPLETE_CHAIN_INVENTORY'
$evidenceRetentionReference = 'REPLACE_WITH_RETENTION_CONTROL_PROOF'
$independentReviewReference = 'REPLACE_WITH_INDEPENDENT_REVIEW_RECORD'
$accessAuditReference = 'REPLACE_WITH_EVIDENCE_ACCESS_AUDIT'
$auditedBy = 'REPLACE_WITH_ACCOUNTABLE_AUDITOR'
```

Use immutable identifiers or URLs without credentials, tokens, secret query
parameters, placeholders, or control characters.

## 5. Record the audit checkpoint

Use the actual completion time from the independent audit record.

```powershell
$auditCompletedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-chain-audit-evidence.ps1 `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -AuditCompletedAtUtc $auditCompletedAtUtc `
  -ChainHeadGateStatus passed `
  -ChainInventoryStatus complete `
  -EvidenceRetentionStatus retained `
  -IndependentReviewStatus passed `
  -AccessAuditStatus passed `
  -ChainHeadGateReference $chainHeadGateReference `
  -ChainInventoryReference $chainInventoryReference `
  -EvidenceRetentionReference $evidenceRetentionReference `
  -IndependentReviewReference $independentReviewReference `
  -AccessAuditReference $accessAuditReference `
  -AuditedBy $auditedBy `
  -MaxHeadEvidenceAgeHours 168 `
  -MaxAuditAgeMinutes 60 `
  -CheckCluster
```

The output is an immutable JSON file under
`.shieldward/production-assurance-chain-audit`.

## 6. Inspect and validate the checkpoint

```powershell
$chainAuditEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-chain-audit' `
  -Filter 'chain-audit-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $chainAuditEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-chain-audit-evidence.ps1 `
  -EvidencePath $chainAuditEvidenceFile.FullName `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, the chain begins at sequence 1, the head
and entry count match, `chainVerified` and `auditPassed` are true, and
the next action remains `continue-scheduled-production-assurance`.

## 7. Apply the freshness gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-chain-audit-gate.ps1 `
  -EvidencePath $chainAuditEvidenceFile.FullName `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded audit checkpoint. It does not schedule a
review, implement retention, alter access, change production, or authorize
removal of any evidence or rollback path.

## 8. Continue scheduled assurance

Continue `docs/production-assurance-recurring.md` at the next recorded
deadline. Create a new audit checkpoint whenever the approved governance
schedule requires one. Failed or unknown audit evidence cannot authorize
continuation; preserve the chain and follow the recorded response action.
