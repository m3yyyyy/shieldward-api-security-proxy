# Release runbook

ShieldWard releases are immutable. Build outputs are produced only by GitHub
Actions from an annotated semantic-version tag. Never replace assets attached
to an existing release or reuse a tag for different source.

## 1. Freeze the candidate

From an up-to-date `main` checkout, confirm that the candidate is clean and
metadata agrees on the intended version:

```powershell
git status -sb
pwsh -NoProfile -File .\scripts\check-release-readiness.ps1 -Version 1.0.0 -RequireClean
git log -1 --oneline
```

For the first release the expected version is `1.0.0`. Later releases must use
the next unused semantic version and update `edge/package.json`,
`edge/package-lock.json`, and `CHANGELOG.md` together.

Do not tag until Continuous Integration, Security, and Containers are green for
the exact commit shown by `git log -1`. Continuous Integration must include a
green `Release candidate` job, and Containers must include a green production
acceptance and outage-drill step.

## 2. Create the immutable tag

Use an annotated tag. Use a signed tag instead when a verified Git signing
identity is configured.

```powershell
git tag -a v1.0.0 -m "ShieldWard v1.0.0"
git show --no-patch --decorate v1.0.0
git push origin v1.0.0
```

Pushing the tag starts both `Release` and the tag-triggered `Containers`
workflow. If the push fails because the tag already exists, stop and inspect the
existing tag; do not force it.

## 3. Verify publication

Both tag workflows must finish successfully. Confirm that the Release page
contains exactly:

- four control-plane binaries for Linux and Windows on AMD64 and ARM64;
- `shieldward-edge-1.0.0.tar.gz`;
- `shieldward-source.spdx.json`;
- `SHA256SUMS`.

Download all assets into a new directory and run:

```powershell
pwsh -NoProfile -File .\scripts\verify-release-assets.ps1 `
  -Directory C:\path\to\downloaded\assets `
  -Version 1.0.0
```

For a public repository, verify attestations as described in
`docs/supply-chain.md`. Record the versioned and `sha-<commit>` container
digests. Deploy only digest-pinned images, never a mutable tag.

## 4. Promote gradually

Deploy to a non-production environment first and complete the
digest-pinned rollout in `docs/staging-rollout.md` plus the environment-specific
checks in `docs/production-acceptance.md`. Attach the sanitized staging evidence
to the change record. If this is the first production installation and no
verified rollback release exists, follow
`docs/initial-production-installation.md`, keep traffic disabled, and establish
the first baseline without inventing older digests. Then use
`docs/production-baseline-and-traffic.md` for the separate, bounded initial
canary approval, followed by `docs/production-canary-and-expansion.md` for the
tamper-detecting observation record and separately approved first expansion.
After its observation window, use `docs/production-progressive-expansion.md`
for the next evidence-bound step, capped at 50 percent total traffic, followed
by `docs/production-second-expansion.md` for the separately approved step capped
at 75 percent total traffic. After its full observation window, use
`docs/production-final-expansion.md` for the separate, exact 75-to-100-percent
approval gate, then close the rollout with the externally enforced full-traffic
evidence and fail-closed acceptance in `docs/production-steady-state.md`.
After acceptance, retain ongoing health and drift evidence through
`docs/production-assurance.md`; material drift requires re-acceptance.
Failed or unknown assurance proceeds through the explicit, tamper-evident
response plan in `docs/production-incident-response.md`; repository scripts do
not execute the production action.
After external execution, require the exact, freshness-bound response evidence
in `docs/production-incident-containment.md` before recovery or restoration.
Then use `docs/production-incident-recovery.md` for a separate, tamper-evident
recovery change and bounded restoration approval. Repository scripts never
apply the traffic change.
After external execution, require
`docs/production-incident-recovery-evidence.md` to prove the exact target,
healthy signals, and rollback readiness before any later step or closure.
For a passed 1-10 percent recovery canary, continue with
`docs/production-incident-recovery-expansion.md` to bind the completed
observation to a separate exact expansion approval capped at 25 percent.
After external execution, require
`docs/production-incident-recovery-expansion-evidence.md` to prove exact
enforcement, healthy signals, rollback readiness, and completed records before
any later recovery step or closure.
For passed evidence at 2-25 percent, continue with
`docs/production-incident-recovery-progressive.md` to observe the proven
boundary and require a separate exact approval for a step of at most 25
percentage points, capped at 50 percent total traffic.
After external execution, require
`docs/production-incident-recovery-progressive-evidence.md` to prove exact
enforcement, healthy signals, rollback readiness, and completed records before
any later recovery step or closure.
For passed progressive evidence at 3-50 percent, continue with
`docs/production-incident-recovery-second-expansion.md` to observe the proven
boundary and require a separate exact approval for a step of at most 25
percentage points, capped at 75 percent total traffic.
After external execution, require
`docs/production-incident-recovery-second-expansion-evidence.md` to prove exact
enforcement, healthy signals, rollback readiness, and completed records before
any later recovery step or closure.
For passed second-expansion evidence at exactly 75 percent, continue with
`docs/production-incident-recovery-final-expansion.md` to observe the proven
boundary and require a separate exact approval for 100 percent traffic. Keep
rollback to 75 percent and emergency disable-to-zero available; the repository
gate remains read-only and does not prove execution or close the incident.
After external execution, require
`docs/production-incident-recovery-final-expansion-evidence.md` to prove exact
100 percent enforcement, healthy signals, rollback readiness, and completed
records. Only passed current evidence may begin independent production
re-acceptance and incident-closure review; it does not itself close the incident.
Complete that separate review with
`docs/production-incident-recovery-closure.md`. Its read-only gate holds traffic
at 100 percent, requires sustained health and passed independent re-acceptance,
preserves rollback to 75 percent, and binds an exact approval before an operator
acts in the authoritative incident system. The repository never closes the
incident automatically.

After the operator records closure externally, require
`docs/production-incident-recovery-closure-evidence.md`. Its freshness-bound
gate must prove the incident is closed, the change record is completed,
post-closure monitoring is healthy, traffic remains exactly 100 percent with
zero mutation, rollback is retained, and audit evidence is complete. Missing
or unknown proof means the incident remains open.

After that evidence passes, follow
`docs/production-post-incident-assurance.md`. Require its minimum assurance
window, sustained health and error-budget evidence, completed security review,
root-cause analysis and retrospective, tracked corrective actions, retained
rollback, and complete audit record. The repository remains read-only; only a
fresh passed gate resumes continuous production assurance.

Then use `docs/production-assurance-resumption.md` to bind that passed outcome
to an active approved scheduler and current complete monitoring. Its gate
requires no drift, externally enforced 100 percent traffic, retained rollback,
and a future next-review deadline before returning to the existing periodic
assurance runbook.

At that first deadline, require
`docs/production-assurance-continuity.md`. It derives the expected time from
the resumption artifact and fails closed for late, missed, unknown, unhealthy,
drifted, non-full-traffic, or missing-rollback evidence. Then require
`docs/production-assurance-recurring.md` for sequence 2 and every later
review so gaps, deadline resets, failed predecessors, and chain tampering fail
closed.

At the approved governance interval, use
`docs/production-assurance-chain-audit.md` to inventory the full retained
sequence, bind its aggregate digest, and require independent retention and
access review. This audit checkpoint is read-only and does not replace the
recurring review gate.

For externally retained checkpoints, follow
`docs/production-assurance-evidence-custody.md`. It requires byte-identical
audit and chain digests plus recorded object-lock, retention, encryption,
least-privilege access, and restore proof without performing those operations.

At the first scheduled external custody review, follow
`docs/production-assurance-custody-review.md`. It revalidates the exact custody
record, current archive inventory and controls, remaining retention, and the
next review deadline without changing the archive or production.

Continue later custody reviews with
`docs/production-assurance-custody-recurring.md`. Its read-only chain rejects
sequence gaps, changed predecessors, late reviews, failed controls, and
retention deadlines that cannot contain the following review.

Audit that custody-review chain with
`docs/production-assurance-custody-chain-audit.md` at each approved governance
checkpoint. The audit requires a contiguous inventory, unchanged root custody,
retained evidence, independent review, least-privilege access, and successful
restore proof without modifying the archive or production.

When the custody audit requires renewal, use
`docs/production-assurance-retention-renewal.md`. Its tamper-evident approval
binds the exact failed audit, requested extension, next-review coverage, and
named authorities before any external archive procedure begins.
After execution, follow
`docs/production-assurance-retention-renewal-evidence.md`; only passed, fresh,
tamper-evident results may establish a renewed custody-review baseline.
Create that bridge with
[the renewed custody-review baseline](production-assurance-renewed-custody-baseline.md)
before resuming the inherited review sequence.
At its inherited deadline, record the review with
[renewed custody-review evidence](production-assurance-renewed-custody-review.md);
failed or unknown controls stop continuation.
Continue subsequent deadlines with
[recurring renewed custody reviews](production-assurance-renewed-custody-recurring.md),
never skipping or rewriting a predecessor.
At the approved checkpoint, record the complete sequence with the
[renewed custody chain audit](production-assurance-renewed-custody-chain-audit.md).
If its action requires another renewal, use the
[renewed retention-renewal plan](production-assurance-renewed-retention-renewal.md)
and do not treat approval as execution evidence. After the external change,
require [renewed retention-renewal evidence](production-assurance-renewed-retention-renewal-evidence.md)
before establishing the
[next renewed custody baseline](production-assurance-next-renewed-custody-baseline.md).

Otherwise, create and approve the tamper-evident plan in
`docs/production-promotion.md`, then run its
read-only production-context and rollback-baseline preflight. Promote a small
production cohort through the approved platform, watch readiness, error
outcomes, policy age, rejected reloads, rate-limit dependency health, circuit
transitions, and drain behavior, then increase traffic only while the release
remains within its error budget.

## 5. Respond to a failed release

If a workflow fails before publication, leave the tag unpromoted, fix the cause
on `main`, and issue a new version. If a defective release is already published,
stop promotion, roll workloads back to the last verified image digests, mark the
GitHub release as affected, and publish a patch version from a reviewed fix.

Deleting and recreating a public tag or silently replacing an asset destroys
the audit trail and is not a rollback. Credential exposure follows the incident
process in `SECURITY.md` and also requires immediate credential rotation.
