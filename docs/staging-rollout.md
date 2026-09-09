# Staging rollout and rollback

Deploy released ShieldWard images to an isolated staging cluster before any
production promotion. The staging baseline proves that the published images,
cluster identity, mounted credentials, policy, health signals, and fail-closed
behavior work together outside the source checkout.

This procedure does not create or print credentials. Keep signing keys and TLS
private keys in the approved secret system and use a dedicated non-production
Kubernetes context. The automation refuses to continue unless the current
context exactly matches the operator-supplied context name.

## 1. Record immutable release inputs

From the GitHub Packages pages, copy the multi-platform manifest digest for
both `v1.0.0` images. Each value must have the form `sha256:` followed by 64
lowercase hexadecimal characters. Verify the image attestations before using
the digests:

```powershell
gh attestation verify `
  oci://ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane@sha256:CONTROL_PLANE_DIGEST `
  --repo m3yyyyy/shieldward-api-security-proxy

gh attestation verify `
  oci://ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge@sha256:EDGE_DIGEST `
  --repo m3yyyyy/shieldward-api-security-proxy
```

Record the release tag, source commit, workflow runs, and both verified digests
in the approved change record.

## 2. Generate the staging overlay

Run the generator from the repository root after replacing both example digest
values with the recorded values:

```powershell
$controlPlaneDigest = 'sha256:REPLACE_WITH_64_HEX_CHARACTERS'
$edgeDigest = 'sha256:REPLACE_WITH_64_HEX_CHARACTERS'

pwsh -NoProfile -File .\scripts\new-staging-overlay.ps1 `
  -Version 1.0.0 `
  -ControlPlaneDigest $controlPlaneDigest `
  -EdgeDigest $edgeDigest
```

The command writes `kustomization.yaml` and `rollout.json` beneath
`.shieldward/staging`. That directory is ignored by Git because it contains
environment-specific promotion state. The overlay references the hardened
base manifests and replaces both image tags with exact digests. It never
contains Kubernetes Secrets.

Inspect the generated inputs before applying them:

```powershell
Get-Content .\.shieldward\staging\rollout.json
kubectl kustomize .\.shieldward\staging
```

Stop if the rendered output contains `latest`, a placeholder, an unexpected
registry, or an image without `@sha256:`.

## 3. Prepare the isolated cluster

Use `kubectl config get-contexts` to identify the dedicated staging context.
Create the `shieldward` namespace and the two required credential Secrets using
the commands and key layout in `docs/containers.md`, preferably through the
cluster's external-secret integration.

The Edge listener certificate used by the automated in-pod probe must include
`shieldward-edge.shieldward.svc.cluster.local` as a DNS SAN. The control-plane
certificate and Edge client identity must retain the DNS and SPIFFE contracts
described in `docs/mutual-tls-and-certificate-rotation.md`.

Review and replace the example policy before the rollout. The real issuer,
audience, JWKS endpoint, and upstream must be reachable through the approved
NetworkPolicy rules. Do not weaken the default-deny decision to make a staging
check pass.

## 4. Deploy and collect evidence

Pass the expected context literally; do not copy it from an unreviewed script:

```powershell
$stagingContext = 'REPLACE_WITH_REVIEWED_STAGING_CONTEXT'

pwsh -NoProfile -File .\scripts\invoke-staging-rollout.ps1 `
  -ExpectedContext $stagingContext `
  -IncludeControlPlaneOutageDrill
```

The rollout tool:

- verifies the exact Kubernetes context and required Secret names;
- renders the overlay and rejects mutable or unexpected image references;
- applies the digest-pinned manifests and waits for both deployments;
- confirms the live deployment specs still use the recorded digests and both
  runtimes report the expected release version;
- runs the control-plane probe and certificate-validated Edge health checks;
- verifies readiness, policy version, default deny, and JWT denial behavior;
- optionally scales only the staging control plane to zero, proves Edge retains
  the last verified policy, restores the original replica count, and verifies
  recovery;
- writes sanitized JSON evidence beneath `.shieldward/evidence` without pod
  logs, Secret values, tokens, or private-key material.

The final output must include `Staging rollout passed`. Attach the evidence JSON
to the approved change record. Separately exercise the real identity provider,
business upstream, Redis dependency when enabled, capacity limits, and ingress
path before approving production traffic.

## 5. Roll back by digest

Keep the last accepted control-plane and Edge digests in the change record. To
roll back, regenerate the staging overlay with the previous release version and
both previous digests, using `-Force` only to replace the two generated staging
files:

```powershell
pwsh -NoProfile -File .\scripts\new-staging-overlay.ps1 `
  -Version PREVIOUS_VERSION `
  -ControlPlaneDigest 'sha256:PREVIOUS_CONTROL_PLANE_DIGEST' `
  -EdgeDigest 'sha256:PREVIOUS_EDGE_DIGEST' `
  -Force

pwsh -NoProfile -File .\scripts\invoke-staging-rollout.ps1 `
  -ExpectedContext $stagingContext
```

Do not use a mutable tag as a rollback target and do not delete or recreate a
release tag. If the failed rollout changed policy or credentials, restore their
last verified versions through their owning systems before resuming promotion.

## 6. Promotion decision

Production promotion requires the staging evidence plus every
environment-specific item in `docs/production-acceptance.md`. A failed check is
a blocked promotion, not an accepted warning. Record the owner, decision time,
approved image digests, rollback authority, and observation window before
sending any production traffic to the new release.
