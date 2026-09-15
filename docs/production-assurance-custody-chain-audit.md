# Production assurance custody chain-audit evidence

Use this runbook after at least one recurring production assurance custody
review has passed. Chapter 57 links every later review to its exact predecessor
and preserves the original custody record. Chapter 58 creates an immutable
governance checkpoint that inventories the entire custody-review chain from
sequence 1 through the selected recurring head.

The audit is evidence-only and does not schedule a review. The repository does
not inspect or alter an archive, renew retention, change access, perform a
restore, delete evidence, or change production. External storage and records
systems remain authoritative.

## 1. Preserve the custody audit boundary

A passed custody chain audit requires all of these conditions:

- the head is an exact passed recurring custody review at sequence 2 or later;
- every predecessor remains present beneath the ignored `.shieldward` state;
- every path, SHA-256 hash, integrity digest, sequence, and deadline matches;
- sequences are contiguous from 1 through the head with no gap or cycle;
- the original custody checksum, chain digest, head sequence, and retention
  deadline remain unchanged across every entry;
- the current custody head gate and independent governance review pass;
- the authoritative inventory is complete and root custody is confirmed;
- retention, least-privilege access, and isolated restore audits pass; and
- every supplied reference identifies current authoritative evidence.

The collector derives the entries, sequence range, count, and aggregate digest.
Operators cannot declare these values. Registration is not enforcement, and a
list of filenames without hash and lineage validation is not a custody audit.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-chain-audit-contract.ps1
```

Its final line must be:

```text
Production assurance custody chain-audit evidence contract passed.
```

The test uses only ignored `.shieldward` data. It verifies sequence-2 and
sequence-3 inventories, rejects a scheduled-only head, and covers failed,
unknown, stale, and tampered audit, head, and interior evidence.

## 3. Select and gate the recurring custody head

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$chainHeadEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-recurring' `
  -Filter 'custody-review-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $chainHeadEvidenceFile) {
  throw 'A recurring production assurance custody-review head was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-recurring-gate.ps1 `
  -EvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

Never edit generated JSON. The audit binds the exact head, every reachable
predecessor, and the unchanged root custody boundary.

## 4. Gather authoritative audit references

```powershell
$chainHeadGateReference = 'REPLACE_WITH_GREEN_CUSTODY_HEAD_GATE'
$chainInventoryReference = 'REPLACE_WITH_COMPLETE_CUSTODY_CHAIN_INVENTORY'
$rootCustodyReference = 'REPLACE_WITH_ROOT_CUSTODY_CONFIRMATION'
$evidenceRetentionReference = 'REPLACE_WITH_RETENTION_CONTROL_PROOF'
$independentReviewReference = 'REPLACE_WITH_INDEPENDENT_GOVERNANCE_REVIEW'
$accessAuditReference = 'REPLACE_WITH_EVIDENCE_ACCESS_AUDIT'
$restoreAuditReference = 'REPLACE_WITH_ISOLATED_RESTORE_AUDIT'
$auditedBy = 'REPLACE_WITH_ACCOUNTABLE_AUDITOR'
```

Use immutable identifiers or URLs without credentials, tokens, secret query
parameters, placeholders, or control characters.

## 5. Record the audit checkpoint

Use the actual completion time from the independent audit record.

```powershell
$auditCompletedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-custody-chain-audit-evidence.ps1 `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -AuditCompletedAtUtc $auditCompletedAtUtc `
  -ChainHeadGateStatus passed `
  -ChainInventoryStatus complete `
  -RootCustodyStatus confirmed `
  -EvidenceRetentionStatus retained `
  -IndependentReviewStatus passed `
  -AccessAuditStatus passed `
  -RestoreAuditStatus passed `
  -ChainHeadGateReference $chainHeadGateReference `
  -ChainInventoryReference $chainInventoryReference `
  -RootCustodyReference $rootCustodyReference `
  -EvidenceRetentionReference $evidenceRetentionReference `
  -IndependentReviewReference $independentReviewReference `
  -AccessAuditReference $accessAuditReference `
  -RestoreAuditReference $restoreAuditReference `
  -AuditedBy $auditedBy `
  -MaxHeadEvidenceAgeHours 2208 `
  -MaxAuditAgeMinutes 60 `
  -CheckCluster
```

The immutable JSON output is written beneath
`.shieldward/production-assurance-custody-chain-audit`.

## 6. Inspect and validate the checkpoint

```powershell
$custodyChainAuditEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-custody-chain-audit' `
  -Filter 'custody-chain-audit-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $custodyChainAuditEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-custody-chain-audit-evidence.ps1 `
  -EvidencePath $custodyChainAuditEvidenceFile.FullName `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, the chain begins at sequence 1, its head and
entry count match, `rootCustodyVerified` and `auditPassed` are true, and the
next action remains `continue-scheduled-production-assurance`.

## 7. Apply the freshness gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-custody-chain-audit-gate.ps1 `
  -EvidencePath $custodyChainAuditEvidenceFile.FullName `
  -ChainHeadEvidencePath $chainHeadEvidenceFile.FullName `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded custody audit checkpoint. It does not
schedule a review, enforce retention, change access, restore an archive, alter
production, or authorize evidence or rollback removal.

## 8. Continue without resetting custody

Continue `docs/production-assurance-custody-recurring.md` at the next recorded
deadline. Create another custody audit checkpoint whenever the approved
governance schedule requires one. Failed or unknown audit evidence cannot
authorize continuation; preserve the chain and follow the recorded action.
