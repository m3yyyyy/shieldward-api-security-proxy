# Production post-incident assurance and retrospective evidence

Use this runbook only after the production recovery incident-closure execution
gate passes. Chapter 49 proves that an authorized operator recorded the
incident as closed in the authoritative external system. This chapter proves a
later assurance window remained healthy and that the root-cause analysis,
corrective-action tracking, and retrospective were recorded.

The repository intentionally provides no command that reopens an incident,
changes traffic, edits a change record, completes a retrospective, or discards
rollback. Operators perform those actions in their authoritative systems. The
scripts here only collect, validate, and gate supplied evidence.

## 1. Preserve the post-closure boundary

Before collecting evidence, confirm all of these facts outside the repository:

- the Chapter 49 closure evidence gate passed;
- the incident remains recorded as closed;
- production traffic remains externally enforced at exactly 100 percent;
- the assurance window covers at least 24 hours after recorded closure;
- health and error-budget evidence covers that entire window;
- the security review and root-cause analysis are complete;
- corrective actions have owners and are tracked outside this repository;
- the retrospective is completed in the authoritative record;
- rollback to 75 percent and emergency disable-to-zero remain retained; and
- the supporting audit evidence is complete.

Unknown assurance or retrospective state is not success. Treat it as
incomplete, retain rollback evidence, and collect authoritative proof.

## 2. Verify the repository contract

From the repository root:

```powershell
pwsh -NoProfile -File .\scripts\test-production-post-incident-assurance-contract.ps1
```

This synthetic test uses only ignored `.shieldward` data. It proves passed,
failed, unknown, stale, mismatched-traffic, and tampering behavior without
contacting production systems.

## 3. Select immutable closure evidence

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$closurePlan = '.shieldward/production-incident-recovery-closure/closure.json'
$closureEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-incident-recovery-closure-evidence' `
  -Filter 'closure-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $closureEvidenceFile) {
  throw 'No production recovery incident-closure evidence was found.'
}

pwsh -NoProfile -File .\scripts\test-production-incident-recovery-closure-evidence-gate.ps1 `
  -EvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

Do not edit or copy values out of a failed or unknown closure artifact to make
it appear passed. The post-incident evidence binds the exact closure artifact
by relative path, SHA-256 hash, and integrity digest.

## 4. Gather authoritative references

Replace every placeholder below with an immutable external identifier or URL.
Do not put credentials, tokens, private keys, or secret query parameters into
the evidence.

```powershell
$closureEvidenceGateReference = 'REPLACE_WITH_CLOSURE_GATE_RUN'
$incidentRecordReference = 'REPLACE_WITH_CLOSED_INCIDENT_RECORD'
$assuranceWindowReference = 'REPLACE_WITH_SUSTAINED_HEALTH_WINDOW'
$errorBudgetReference = 'REPLACE_WITH_ERROR_BUDGET_REPORT'
$securityReviewReference = 'REPLACE_WITH_SECURITY_REVIEW'
$rootCauseAnalysisReference = 'REPLACE_WITH_ROOT_CAUSE_ANALYSIS'
$correctiveActionsReference = 'REPLACE_WITH_TRACKED_ACTION_REGISTER'
$retrospectiveReference = 'REPLACE_WITH_RETROSPECTIVE_RECORD'
$trafficStateReference = 'REPLACE_WITH_100_PERCENT_TRAFFIC_PROOF'
$rollbackRetentionReference = 'REPLACE_WITH_RETAINED_ROLLBACK_PROOF'
$auditEvidenceReference = 'REPLACE_WITH_AUDIT_EVIDENCE_BUNDLE'
$collectedBy = 'REPLACE_WITH_COLLECTOR_IDENTITY'
```

The collector rejects empty values, `REPLACE` placeholders, control
characters, and values longer than 256 characters.

## 5. Record the post-incident evidence

Wait until the minimum assurance window has elapsed. Then record only what the
authoritative sources currently prove:

```powershell
$assessedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-post-incident-assurance-evidence.ps1 `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -AssessedAtUtc $assessedAtUtc `
  -ObservedTrafficPercent 100 `
  -TrafficEnforcementStatus confirmed `
  -CurrentIncidentStatus closed `
  -SustainedHealthStatus healthy `
  -ErrorBudgetStatus within-budget `
  -SecurityReviewStatus complete `
  -RootCauseAnalysisStatus complete `
  -CorrectiveActionsStatus tracked `
  -RetrospectiveStatus completed `
  -RollbackRetentionStatus retained `
  -AuditEvidenceStatus complete `
  -ClosureEvidenceGateReference $closureEvidenceGateReference `
  -IncidentRecordReference $incidentRecordReference `
  -AssuranceWindowReference $assuranceWindowReference `
  -ErrorBudgetReference $errorBudgetReference `
  -SecurityReviewReference $securityReviewReference `
  -RootCauseAnalysisReference $rootCauseAnalysisReference `
  -CorrectiveActionsReference $correctiveActionsReference `
  -RetrospectiveReference $retrospectiveReference `
  -TrafficStateReference $trafficStateReference `
  -RollbackRetentionReference $rollbackRetentionReference `
  -AuditEvidenceReference $auditEvidenceReference `
  -CollectedBy $collectedBy `
  -MinimumAssuranceWindowHours 24 `
  -MaxClosureEvidenceAgeHours 720 `
  -MaxAssessmentAgeMinutes 60 `
  -CheckCluster
```

The output is an immutable JSON record under
`.shieldward/production-post-incident-assurance`. A passed result requires
every supplied status to be affirmative. A known adverse status fails. Any
unknown status produces an unknown outcome and fails closed.

## 6. Inspect and validate the artifact

```powershell
$assuranceEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-post-incident-assurance' `
  -Filter 'assurance-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $assuranceEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-post-incident-assurance-evidence.ps1 `
  -EvidencePath $assuranceEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm `outcome` is `passed`, the incident remains `closed`, sustained health
is `healthy`, the error budget is `within-budget`, the retrospective is
recorded, traffic remains exactly 100 with zero mutation, and rollback remains
retained. Never edit generated JSON.

## 7. Apply the freshness-bound assurance gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-post-incident-assurance-gate.ps1 `
  -EvidencePath $assuranceEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the supplied post-incident assurance and
retrospective record. It does not guarantee future health, complete external
work, mutate traffic, reopen or close incidents, or authorize rollback removal.

## 8. Follow the recorded outcome

- Passed evidence resumes continuous production assurance while rollback and
  audit artifacts follow organizational retention policy.
- Failed evidence reopens or escalates the incident through the authoritative
  process and preserves rollback.
- Unknown evidence keeps assurance incomplete until authoritative proof is
  collected.

Attach the immutable artifact and gate output to the incident, retrospective,
and corrective-action records.
