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
to the change record. Promote a small production cohort, watch readiness, error
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
