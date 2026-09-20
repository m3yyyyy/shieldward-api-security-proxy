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

For passed second-expansion evidence at exactly 75 percent, follow
`docs/production-incident-recovery-final-expansion.md`. Its read-only gate
binds a complete healthy observation to separate exact approval for 100
percent traffic while preserving rollback to 75 percent or emergency disable.
Approval remains intent, not execution evidence or incident closure.

After external execution, require
`docs/production-incident-recovery-final-expansion-evidence.md`. Its
freshness-bound gate proves the exact externally enforced 100 percent target,
healthy verification, ready rollback to 75 percent, and completed records.
The result permits independent re-acceptance and closure review to begin but
does not itself authorize incident closure.

For passed current evidence, follow
`docs/production-incident-recovery-closure.md`. Its read-only closure gate
requires a sustained healthy 100 percent observation, passed independent
production re-acceptance, updated incident records, a separate approved closure
change, and exact closure approval. It keeps rollback to 75 percent ready and
does not mutate traffic or close the incident.

After an authorized operator records closure externally, require
`docs/production-incident-recovery-closure-evidence.md`. Its immutable,
freshness-bound artifact binds the approved closure plan to the authoritative
closed incident, completed change, healthy post-closure monitoring, exact
100 percent traffic, retained rollback, and complete audit evidence. Missing
or unknown closure proof means the incident remains open.

For passed closure evidence, follow
`docs/production-post-incident-assurance.md`. Its immutable artifact binds that
closure to a minimum post-incident observation window, healthy error-budget
and security evidence, completed root-cause analysis and retrospective,
tracked corrective actions, and retained rollback. Only a fresh passed gate
resumes this continuous assurance loop; unknown evidence fails closed.

Before returning from that post-incident sequence to this periodic loop, use
`docs/production-assurance-resumption.md`. Its freshness- and schedule-bound
bridge proves monitoring coverage, an active external scheduler, no material
drift, exact 100 percent traffic, and retained rollback. A passed bridge hands
control back to this runbook; it does not itself schedule future reviews.

The first review after that bridge follows
`docs/production-assurance-continuity.md`. It proves the recorded deadline was
met and binds current health, drift, traffic, and rollback evidence to that
review. After its gate passes, use
`docs/production-assurance-recurring.md` so each later review binds the exact
previous passed artifact and cannot reset the sequence or deadline.

Use `docs/production-assurance-chain-audit.md` for approved governance
checkpoints after recurring evidence exists. It inventories and verifies the
retained chain but does not replace or reschedule an assurance review.

When that checkpoint is retained externally, use
`docs/production-assurance-evidence-custody.md` to bind its exact checksum
and chain digest to current storage-control and restore evidence.

At the first approved custody-review deadline, follow
`docs/production-assurance-custody-review.md` to revalidate availability,
inventory, storage controls, restorability, remaining retention, and the next
review boundary.

For sequence 2 and every later custody review, use
`docs/production-assurance-custody-recurring.md`. It binds each review to its
exact predecessor and preserves the original custody and retention identity.

Use `docs/production-assurance-custody-chain-audit.md` after recurring custody
evidence exists. Its governance checkpoint proves that the full custody-review
chain and original custody identity remain present, contiguous, retained,
access-controlled, restorable, and tamper-evident.

When retention is missing or insufficient, stop and use
`docs/production-assurance-retention-renewal.md` to create an independently
approved external renewal plan. Approval is not proof of execution.
Require `docs/production-assurance-retention-renewal-evidence.md` after the
external change and before establishing a renewed custody-review baseline.
Use the
[renewed custody-review baseline](production-assurance-renewed-custody-baseline.md)
to preserve the original chain while deriving the next sequence and deadline.
At that deadline, use
[renewed custody-review evidence](production-assurance-renewed-custody-review.md)
to revalidate external controls and continue without resetting the sequence.
Continue every later deadline with
[recurring renewed custody reviews](production-assurance-renewed-custody-recurring.md),
using the exact latest passed review as the predecessor.
Audit that continued chain with the
[renewed custody chain audit](production-assurance-renewed-custody-chain-audit.md)
at the approved governance checkpoint.
If that audit reports retention at risk, use the
[renewed retention-renewal plan](production-assurance-renewed-retention-renewal.md)
before any later external renewal procedure. After external execution, require
[renewed retention-renewal evidence](production-assurance-renewed-retention-renewal-evidence.md)
before establishing the
[next renewed custody baseline](production-assurance-next-renewed-custody-baseline.md).
At its inherited deadline, use the
[next renewed custody review](production-assurance-next-renewed-custody-review.md)
to record sequence 7 and revalidate every external archive control.
Continue sequence 8 and every later deadline with
[recurring next-renewed custody reviews](production-assurance-next-renewed-custody-recurring.md),
always binding the exact latest passed predecessor.
At the approved generation-3 governance checkpoint, use the
[next-renewed custody chain audit](production-assurance-next-renewed-custody-chain-audit.md)
to inventory sequences 7 through the exact recurring head without resetting
the chain or rewriting either renewal generation.
If it records retention at risk, stop and create the independently approved
[next-renewed retention-renewal plan](production-assurance-next-renewed-retention-renewal.md).
Approval authorizes only the exact external procedure and is not execution
evidence.
After external execution, require
[next-renewed retention-renewal evidence](production-assurance-next-renewed-retention-renewal-evidence.md)
before establishing the
[generation-4 custody baseline](production-assurance-generation-4-custody-baseline.md).
A passed baseline gate preserves the full inherited lineage and authorizes only
continuation to
[generation-4 custody review sequence 10](production-assurance-generation-4-custody-review.md).
That review must revalidate every external archive control at the inherited
deadline before any later sequence continues. Continue with
[recurring generation-4 custody reviews](production-assurance-generation-4-custody-recurring.md),
which bind the exact latest passed predecessor and derive sequences 11 and
later without gaps, resets, or lineage changes. At an approved checkpoint, use
the [generation-4 custody chain audit](production-assurance-generation-4-custody-chain-audit.md)
to reconstruct sequence 10 through the selected recurring head and verify the
complete third-renewal lineage without scheduling or changing a review. If
that audit records retention at risk, stop and create the independently
approved [generation-4 retention-renewal plan](production-assurance-generation-4-retention-renewal.md).
Approval authorizes only the exact external procedure and is not execution
evidence. After that procedure runs, record
[generation-4 retention-renewal execution evidence](production-assurance-generation-4-retention-renewal-evidence.md).
Only a fresh passed record may prove renewal sequence 4 and hand off the exact
generation-5 retention boundary; failed, unknown, stale, insufficient, or
altered evidence leaves the gate closed. Establish the
[generation-5 custody baseline](production-assurance-generation-5-custody-baseline.md)
only from that exact record. The baseline preserves review head 12 and derives
sequence 13 without scheduling or completing a review. Complete that inherited
checkpoint through the [generation-5 custody review](production-assurance-generation-5-custody-review.md),
which must revalidate every external archive control before continuation. Use
[recurring generation-5 custody reviews](production-assurance-generation-5-custody-recurring.md)
for sequence 14 and later, always binding the exact latest passed predecessor.
At an approved checkpoint, use the
[generation-5 custody chain audit](production-assurance-generation-5-custody-chain-audit.md)
to reconstruct sequence 13 through the selected recurring head and verify the
complete four-renewal lineage without scheduling or changing a review. If
that audit records retention at risk, stop and create the independently
approved [generation-5 retention-renewal plan](production-assurance-generation-5-retention-renewal.md).
Approval authorizes only the exact external procedure and is not execution
evidence. After that procedure runs, record
[generation-5 retention-renewal execution evidence](production-assurance-generation-5-retention-renewal-evidence.md).
Only a fresh passed record may prove renewal sequence 5 and hand off the exact
generation-6 retention boundary; failed, unknown, stale, insufficient, or
altered evidence leaves the gate closed. Establish the
[generation-6 custody baseline](production-assurance-generation-6-custody-baseline.md)
only from that exact record. The baseline preserves review head 15 and derives
sequence 16 without scheduling or completing a review.
