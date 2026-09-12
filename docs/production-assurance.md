# Continuous production assurance and drift detection

This procedure begins after `docs/production-steady-state.md` has produced
passed full-traffic evidence and the rollout has been accepted. It records
periodic, tamper-detecting assurance snapshots for the accepted immutable
candidate and applies a freshness-bound operational gate.

The accepted full-traffic artifact is a historical baseline, not a claim that
production is healthy forever. Each assurance snapshot must use current
authoritative monitoring, traffic, and drift evidence. The scripts are
read-only with respect to Kubernetes, the traffic controller, and external
change systems.

## 1. Define the assurance boundary

Each review must establish all of the following:

1. the external controller still reports exactly 100 percent traffic;
2. the live control-plane and Edge images still match the accepted digests;
3. the verified policy, configuration, service identity, certificates, and
   routing have no unapproved drift;
4. error budget, alerts, functional behavior, dependencies, operations,
   capacity, and security signals are all available and healthy; and
5. the prior 75 percent rollback cohort plus emergency zero-traffic procedure
   remain available to the recorded authority.

Unknown, missing, failed, stale, overdue, or tampered evidence fails closed.
Confirmed image, policy, configuration, identity, or routing drift requires a
new acceptance through the applicable rollout gate before continuing.

## 2. Test the local contract

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-contract.ps1
```

Its final line must be:

```text
Continuous production assurance and drift detection contract passed.
```

The test uses only synthetic artifacts beneath `.shieldward`; it never
contacts production or schedules recurring work.

## 3. Collect a current assurance snapshot

Use exact references from the authoritative traffic, monitoring, inventory,
identity, certificate, and configuration systems. Never infer a clear value
from missing data.

```powershell
$productionContext = 'REPLACE_WITH_REVIEWED_PRODUCTION_CONTEXT'
$acceptedEvidence = '.shieldward/production-full-traffic-evidence/evidence.json'
$finalPlan = '.shieldward/production-final-expansion/expansion.json'
$secondEvidence = '.shieldward/production-second-expansion-evidence/evidence.json'
$secondPlan = '.shieldward/production-second-expansion/expansion.json'
$progressiveEvidence = '.shieldward/production-progressive-evidence/evidence.json'
$progressivePlan = '.shieldward/production-progressive/expansion.json'
$expansionEvidence = '.shieldward/production-expansion-evidence/evidence.json'
$expansionPlan = '.shieldward/production-expansion/expansion.json'
$canaryEvidence = '.shieldward/production-canary/evidence.json'
$trafficPlan = '.shieldward/production-traffic/activation.json'
$baselineEvidence = '.shieldward/production-baseline/baseline-1.0.0-REPLACE_TIMESTAMP.json'
$initialPlan = '.shieldward/production-initial/installation.json'
$stagingEvidence = '.shieldward/evidence/staging-1.0.0-REPLACE_TIMESTAMP.json'

kubectl config use-context $productionContext

pwsh -NoProfile -File .\scripts\new-production-assurance-evidence.ps1 `
  -AcceptedFullTrafficEvidencePath $acceptedEvidence `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -ObservedTrafficPercent 100 `
  -ReviewIntervalMinutes 60 `
  -TrafficStateReference 'REPLACE TRAFFIC STATE EVIDENCE' `
  -MonitoringEvidenceReference 'REPLACE MONITORING EVIDENCE' `
  -DriftEvidenceReference 'REPLACE DRIFT SCAN EVIDENCE' `
  -ReviewedBy 'REPLACE REVIEWER' `
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
  -RoutingDriftStatus clear
```

The output is a timestamped JSON file in `.shieldward/production-assurance`.
The collector validates the complete accepted evidence chain and current live
workloads but does not read Secret values or change production.

## 4. Inspect and validate the snapshot

```powershell
$assuranceFile = Get-ChildItem .\.shieldward\production-assurance\assurance-*.json |
  Sort-Object Name -Descending |
  Select-Object -First 1

Get-Content -LiteralPath $assuranceFile.FullName

pwsh -NoProfile -File .\scripts\test-production-assurance-evidence.ps1 `
  -EvidencePath $assuranceFile.FullName `
  -AcceptedFullTrafficEvidencePath $acceptedEvidence `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -CheckCluster
```

The validator recomputes the decision and integrity digest. Do not repair a
failed artifact by editing JSON; collect new evidence after resolving the
underlying condition.

## 5. Apply the freshness-bound assurance gate

```powershell
pwsh -NoProfile -File .\scripts\test-production-assurance-gate.ps1 `
  -EvidencePath $assuranceFile.FullName `
  -AcceptedFullTrafficEvidencePath $acceptedEvidence `
  -FinalExpansionPlanPath $finalPlan `
  -SecondExpansionEvidencePath $secondEvidence `
  -SecondExpansionPlanPath $secondPlan `
  -ProgressiveEvidencePath $progressiveEvidence `
  -ProgressivePlanPath $progressivePlan `
  -ExpansionEvidencePath $expansionEvidence `
  -ExpansionPlanPath $expansionPlan `
  -CanaryEvidencePath $canaryEvidence `
  -TrafficPlanPath $trafficPlan `
  -BaselineEvidencePath $baselineEvidence `
  -InitialPlanPath $initialPlan `
  -StagingEvidencePath $stagingEvidence `
  -ExpectedProductionContext $productionContext `
  -MaxEvidenceAgeMinutes 60 `
  -CheckCluster
```

Acceptance requires a passed snapshot, no material drift, exact full traffic,
and a review that is neither stale nor overdue. Attach the snapshot and gate
output to the authoritative operational record.

## 6. Run reviews from an approved scheduler

The repository intentionally does not schedule production access. Configure
the cadence in an approved external operations system with a protected runner,
least-privilege credentials, evidence retention, and an accountable reviewer.
The configured interval must match the snapshot. A missed run makes the prior
snapshot overdue; it must never be treated as continuing evidence.

## 7. Respond to drift or unhealthy state

- Confirmed image, policy, configuration, identity, or routing drift requires
  re-acceptance through the applicable production rollout gate.
- Missing or unknown evidence requires investigation and a new snapshot.
- An expiring certificate requires rotation and fresh evidence; an invalid
  certificate or security incident requires disablement and investigation.
- Other health or capacity failures require the recorded rollback or disable
  response and incident/change evidence.
- Restore the prior 75 percent cohort only for an approved, bounded response
  where candidate correctness remains intact.
- For security, correctness, identity, or unknown-state risk, disable traffic,
  confirm zero traffic, and follow the approved removal procedure if needed.

Preserve failed snapshots. They are audit evidence, not files to overwrite.

Use `docs/production-incident-response.md` to convert a current failed or
unknown snapshot into a tamper-evident, explicitly approved response plan. Its
scripts remain read-only; execution stays with the authoritative incident,
traffic, deployment, and identity systems.

After external execution, use `docs/production-incident-containment.md` to
prove that the approved response reached its exact traffic boundary. Approval
alone is not containment evidence.

When containment passes, follow `docs/production-incident-recovery.md`. Its
fail-closed readiness and approval gate is required before any externally
controlled traffic restoration.

After execution, require `docs/production-incident-recovery-evidence.md` before
resuming assurance or considering another bounded recovery step. An approved
recovery plan alone is not execution evidence.

When that evidence proves a 1-10 percent recovery canary, follow
`docs/production-incident-recovery-expansion.md`. It binds a complete healthy
canary observation to one separately approved expansion capped at 25 percent;
it does not route traffic or close the incident.

After the external controller executes that approved target, require
`docs/production-incident-recovery-expansion-evidence.md`. Its freshness-bound
gate proves only the exact recorded percentage and preserves rollback; another
increase and incident closure remain separate decisions.

For passed expansion evidence at 2-25 percent, follow
`docs/production-incident-recovery-progressive.md`. Its read-only gate binds a
healthy observation to one separately approved increase of no more than 25
percentage points and no more than 50 percent total traffic. Approval is not
execution evidence or incident closure.

After external execution, require
`docs/production-incident-recovery-progressive-evidence.md`. Its freshness-bound
gate proves only the exact recorded target and preserves rollback to the prior
boundary; further recovery and incident closure remain separate decisions.

For passed progressive evidence at 3-50 percent, follow
`docs/production-incident-recovery-second-expansion.md`. Its read-only gate
binds a complete healthy observation to one separately approved increase of no
more than 25 percentage points and no more than 75 percent total traffic.
Approval remains intent, not execution evidence or incident closure.

After external execution, require
`docs/production-incident-recovery-second-expansion-evidence.md`. Its
freshness-bound gate proves only the exact recorded target and preserves
rollback to the progressive boundary; any later recovery step and incident
closure remain separate decisions.
