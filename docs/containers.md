# Hardened containers and Kubernetes deployment

ShieldWard provides separate control-plane and Edge images. Neither image
contains a policy, signing key, public key, or TLS material. All runtime
configuration is mounted or injected by the deployment platform.

Both images run as non-root users, declare health checks, and support read-only
root filesystems. The control plane uses a `scratch` runtime image. The Edge
image contains only Node.js, compiled application files, and production
dependencies. Base images are pinned by immutable digest and updated through
Dependabot.

## Local Docker Compose stack

Docker Engine with Compose v2 is required. From the repository root, generate a
local signing pair if one does not already exist:

```powershell
go run ./cmd/shieldwardd keygen
```

Generate a local-only certificate authority and separate service certificates:

```powershell
pwsh -NoProfile -File .\scripts\new-container-tls.ps1
```

The script refuses to overwrite existing certificates. Use `-Force` only when
intentionally rotating the local development certificates. All generated files
remain under the ignored `.shieldward` directory. The development CA is not a
production trust anchor and should not be installed as a system-wide trusted CA.

Validate and start the stack:

```powershell
docker compose config --quiet
docker compose up --build --detach --wait --wait-timeout 180
```

Verify both readiness endpoints using the generated CA:

```powershell
docker compose exec -T control-plane /usr/local/bin/shieldwardd probe
curl.exe --fail --show-error --cacert .\.shieldward\containers\ca.pem https://127.0.0.1:8787/readyz
```

Inspect logs and stop the stack:

```powershell
docker compose logs --no-color
docker compose down --volumes --remove-orphans
```

The Compose stack does not publish the control-plane port. Edge is the only
host-facing service and binds only to host loopback. The control plane has no
external network, while Edge has a separate egress network for HTTPS identity
and upstream calls. Both services drop Linux capabilities, prevent privilege
escalation, limit processes and memory, and mount credentials read-only.

## Kubernetes prerequisites

The base manifests under `deploy/kubernetes/base` are secure starting points,
not a complete environment-specific deployment. Before applying them:

1. Replace the example policy endpoints and identifiers.
2. Issue separate production certificates. The control-plane certificate must
   include `shieldward-control-plane.shieldward.svc.cluster.local`; the Edge
   certificate must include its client-facing DNS name.
3. Store the signing private key and TLS private keys in a managed secret store.
4. Replace both example image tags with immutable image digests.
5. Review resource limits and NetworkPolicies against the real upstreams, DNS
   service labels, ingress controller, and CNI implementation.

Create the namespace first:

```powershell
kubectl apply -f .\deploy\kubernetes\base\namespace.yaml
```

Create the expected secrets directly from protected files. These commands do
not create secret manifests in the repository:

```powershell
kubectl -n shieldward create secret generic shieldward-control-plane-credentials `
  --from-file=signing-key.pem=.\.shieldward\private.pem `
  --from-file=tls-cert.pem=C:\secure\control-plane-cert.pem `
  --from-file=tls-key.pem=C:\secure\control-plane-key.pem `
  --from-file=tls-ca.pem=C:\secure\control-plane-ca.pem

kubectl -n shieldward create secret generic shieldward-edge-credentials `
  --from-file=control-plane-public.pem=.\.shieldward\public.pem `
  --from-file=control-plane-ca.pem=C:\secure\control-plane-ca.pem `
  --from-file=tls-cert.pem=C:\secure\edge-cert.pem `
  --from-file=tls-key.pem=C:\secure\edge-key.pem
```

Replace `C:\secure\...` with actual protected paths. Prefer the cluster's
external-secret integration over long-lived local files when available.

Pin the release images by digest, then apply the manifests:

```powershell
kubectl apply -k .\deploy\kubernetes\base
kubectl -n shieldward set image deployment/shieldward-control-plane control-plane=ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane@sha256:REPLACE_WITH_DIGEST
kubectl -n shieldward set image deployment/shieldward-edge edge=ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge@sha256:REPLACE_WITH_DIGEST
kubectl -n shieldward rollout status deployment/shieldward-control-plane
kubectl -n shieldward rollout status deployment/shieldward-edge
```

The Edge ingress policy is fail-closed. Label only the dedicated ingress
controller namespace that is permitted to reach ShieldWard:

```powershell
kubectl label namespace ingress-nginx shieldward.dev/edge-access=allowed --overwrite
```

Change `ingress-nginx` if a different dedicated namespace is used. The supplied
egress policy allows cluster DNS, the ShieldWard control plane, and outbound TCP
443. Add narrowly scoped rules if an upstream uses another port or IPv6.

The base deployment uses one Edge replica with the in-memory rate limiter. For
two or more replicas, configure the TLS Redis overlay described in
`docs/distributed-rate-limiting.md` so every replica enforces the same counter.

## Container CI and releases

The `Containers` workflow builds both images, verifies their configured non-root
users, runs smoke commands, scans final images for high and critical known
vulnerabilities, and launches the TLS Compose topology on every push and pull
request.

A semantic-version tag publishes multi-platform Linux AMD64 and ARM64 images to
GitHub Container Registry with OCI provenance and SBOMs. Public-repository image
digests also receive GitHub attestations. Verify a published image before use:

```powershell
gh attestation verify oci://ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane:v0.1.0 --repo m3yyyyy/shieldward-api-security-proxy
```

Do not create a release tag until all regular CI, Security, and Containers jobs
are green for the exact commit being released.
