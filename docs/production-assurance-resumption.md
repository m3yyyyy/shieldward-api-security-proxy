# Continuous production assurance resumption evidence

Use this runbook only after the post-incident assurance and retrospective gate
passes. That artifact closes the incident-review sequence; this separate bridge
proves that ordinary continuous monitoring has been re-established for the same
immutable candidate and 100 percent traffic boundary.

The repository intentionally provides no command that activates a scheduler,
changes traffic, edits an incident, or removes rollback. Those actions remain
in authoritative external systems. These scripts only collect, validate, and
gate supplied resumption evidence.

## 1. Establish the resumption boundary

Before collecting evidence, confirm all of the following externally:

- the Chapter 50 post-incident gate passed;
- the monitoring scheduler is active at an approved review interval;
- required production signals and drift checks have complete coverage;
- production traffic remains externally enforced at exactly 100 percent;
- error budget, alerts, functionality, dependencies, operations, capacity,
  and security are healthy;
- image, policy, configuration, identity, certificate, and routing state has
  no unapproved drift;
- rollback to 75 percent and emergency disable-to-zero remain retained; and
- an accountable reviewer has approved the evidence references.

An active scheduler is not proof that monitoring data exists. Unknown schedule,
coverage, health, drift, traffic, or rollback state blocks resumption.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-resumption-contract.ps1
```

Its final line must be:

```text
Continuous production assurance resumption evidence contract passed.
```

The test uses synthetic artifacts beneath `.shieldward`. It covers passed,
failed, unknown, stale, drift, inactive-schedule, missing-rollback, and
tampering behavior without contacting production.

## 3. Select the passed post-incident artifact

```powershell
$productionContext = 'REPLACE_WITH_EXACT_PRODUCTION_CONTEXT'
$closurePlan = '.shieldward/production-incident-recovery-closure/closure.json'
$closureEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-incident-recovery-closure-evidence' `
  -Filter 'closure-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
$postIncidentEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-post-incident-assurance' `
  -Filter 'assurance-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $closureEvidenceFile -or $null -eq $postIncidentEvidenceFile) {
  throw 'Required closure or post-incident evidence was not found.'
}

pwsh -NoProfile -File .\scripts\test-production-post-incident-assurance-gate.ps1 `
  -EvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

The resumption artifact binds this exact post-incident file by relative path,
SHA-256 hash, and integrity digest. Never edit generated JSON.

## 4. Gather authoritative references

```powershell
$postIncidentGateReference = 'REPLACE_WITH_POST_INCIDENT_GATE_RUN'
$assuranceScheduleReference = 'REPLACE_WITH_APPROVED_SCHEDULER_RECORD'
$trafficStateReference = 'REPLACE_WITH_100_PERCENT_TRAFFIC_PROOF'
$monitoringEvidenceReference = 'REPLACE_WITH_MONITORING_COVERAGE_PROOF'
$driftEvidenceReference = 'REPLACE_WITH_CURRENT_DRIFT_SCAN'
$rollbackRetentionReference = 'REPLACE_WITH_RETAINED_ROLLBACK_PROOF'
$reviewedBy = 'REPLACE_WITH_ACCOUNTABLE_REVIEWER'
```

Use immutable identifiers or URLs without credentials, tokens, or private
query parameters. Empty, placeholder, control-character, and overlong values
are rejected.

## 5. Record assurance resumption

Record only facts proved by the current external sources:

```powershell
$resumedAtUtc = [DateTimeOffset]::UtcNow

pwsh -NoProfile -File .\scripts\new-production-assurance-resumption-evidence.ps1 `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -ResumedAtUtc $resumedAtUtc `
  -ObservedTrafficPercent 100 `
  -ReviewIntervalMinutes 60 `
  -TrafficEnforcementStatus confirmed `
  -AssuranceScheduleStatus active `
  -MonitoringCoverageStatus complete `
  -ErrorBudgetStatus within-budget `
  -AlertStatus clear `
  -FunctionalStatus passed `
  -DependencyStatus healthy `
  -OperationalStatus healthy `
  -CapacityStatus healthy `
  -SecurityStatus clear `
  -ImageDriftStatus clear `
  -PolicyDriftStatus clear `
  -ConfigurationDriftStatus clear `
  -IdentityDriftStatus clear `
  -CertificateStatus healthy `
  -RoutingDriftStatus clear `
  -RollbackRetentionStatus retained `
  -PostIncidentGateReference $postIncidentGateReference `
  -AssuranceScheduleReference $assuranceScheduleReference `
  -TrafficStateReference $trafficStateReference `
  -MonitoringEvidenceReference $monitoringEvidenceReference `
  -DriftEvidenceReference $driftEvidenceReference `
  -RollbackRetentionReference $rollbackRetentionReference `
  -ReviewedBy $reviewedBy `
  -MaxPostIncidentEvidenceAgeHours 168 `
  -MaxResumptionAgeMinutes 60 `
  -CheckCluster
```

The output is an immutable timestamped JSON file under
`.shieldward/production-assurance-resumption`. Confirmed material drift has a
specific re-acceptance action. Security incidents and invalid certificates
require disablement and investigation. Other failures preserve rollback and
block resumption; unknown evidence requires investigation and refresh.

## 6. Inspect and validate the artifact

```powershell
$resumptionEvidenceFile = Get-ChildItem -LiteralPath `
  '.\.shieldward\production-assurance-resumption' `
  -Filter 'resumption-*.json' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $resumptionEvidenceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-resumption-evidence.ps1 `
  -EvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

Confirm the outcome is `passed`, the scheduler is `active`, monitoring coverage
is `complete`, traffic is exactly 100 with zero mutation, every health and
drift status passes, rollback is `retained`, and `assuranceResumed` is true.

## 7. Apply the freshness and schedule gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-resumption-gate.ps1 `
  -EvidencePath $resumptionEvidenceFile.FullName `
  -PostIncidentEvidencePath $postIncidentEvidenceFile.FullName `
  -ClosureEvidencePath $closureEvidenceFile.FullName `
  -ClosurePlanPath $closurePlan `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

A green gate proves only the recorded resumption state. It does not activate a scheduler,
guarantee the next review, authorize drift, mutate traffic, or permit rollback
evidence to be removed.

## 8. Continue the existing assurance loop

After a passed gate, follow `docs/production-assurance.md` for each scheduled
snapshot. A missed or overdue review, a failed signal, confirmed drift, or an
unknown state follows that runbook's fail-closed response. Attach the immutable
resumption artifact and gate output to the incident and operational records.
