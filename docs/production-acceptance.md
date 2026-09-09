# Production acceptance

Production acceptance is a release gate, not a substitute for unit,
integration, vulnerability, and deployment-specific testing. Evidence must be
tied to the exact commit and immutable image digests being promoted.

## Automated acceptance contract

`scripts/test-production-acceptance.ps1` runs against the hardened Compose
topology and verifies:

- the Compose configuration is valid and the control plane is ready;
- Edge health and readiness are available only through certificate-validated
  HTTPS;
- readiness identifies a verified `sha256:` policy version;
- responses include the expected cache and browser hardening headers;
- an unmatched route is denied with `403 default_deny`;
- a protected route without a valid bearer token is denied with
  `401 jwt_invalid`;
- the control-plane configuration API returns `401` without a client
  certificate and `200` only with the configured Edge client identity;
- during a deliberate control-plane outage, Edge remains ready and continues
  enforcing the last verified policy;
- after control-plane recovery, readiness and fail-closed enforcement remain
  intact.

The GitHub `Containers` workflow runs this contract with the outage drill on
every push and pull request. Failed runs preserve Compose logs before cleanup.
The `Release candidate` job in Continuous Integration independently assembles
the versioned binaries, Edge archive, SBOM, and checksums, then verifies their
inventory and embedded version before any release tag exists.

## Local execution

The test controls the control-plane container during the outage drill. Use a
dedicated local stack with no production traffic.

```powershell
go run ./cmd/shieldwardd keygen
pwsh -NoProfile -File .\scripts\new-container-tls.ps1
docker compose up --build --detach --wait --wait-timeout 180
pwsh -NoProfile -File .\scripts\test-production-acceptance.ps1 -IncludeFailureDrills
docker compose down --volumes --remove-orphans
```

If local credentials already exist, neither generation command should be run
again. The certificate generator refuses to overwrite material unless `-Force`
is explicitly supplied.

The final line must be:

```text
Production acceptance tests passed.
```

## Environment-specific sign-off

Before the first production deployment, record the following outside the
repository in the approved change or incident system:

1. source commit, release tag, release-asset hashes, and container digests;
2. successful Continuous Integration, Security, Containers, and Release runs;
3. attestation and checksum verification results;
4. production DNS, issuer, audience, JWKS, upstream, CA, and SPIFFE identity
   review;
5. measured latency, concurrency, rate-limit, circuit, and drain settings;
6. restore evidence for signing keys, TLS material, policy source, and Redis;
7. owners and rollback authority for the deployment window;
8. results of the target-environment drills in `docs/failure-drills.md`.

The bundled Compose acceptance policy intentionally does not contact a real
identity provider or business upstream. JWT cryptography, proxying, rate-limit
behavior, overload handling, and circuit transitions are covered by the normal
test suites. Each target environment must additionally test its real identity
provider and upstreams from a non-production client before receiving traffic.

Use the digest-pinned staging procedure in `docs/staging-rollout.md` to collect
the cluster rollout baseline and sanitized evidence. That baseline supplements,
but does not replace, the environment-specific sign-off items above.

After staging succeeds, use the decision gate in
`docs/production-promotion.md`. It binds the candidate to the staging evidence,
the exact production context, an explicit approval record, a bounded
observation window, and previously verified rollback digests. The gate does not
deploy workloads or enforce production traffic routing.

When no verified production baseline exists yet, use
`docs/initial-production-installation.md` instead. It keeps traffic disabled,
requires an empty target and approved removal path, and never invents rollback
digests for a release that was not previously deployed.

After that initial installation exists but before any production traffic is
enabled, follow `docs/production-baseline-and-traffic.md`. It captures the live
traffic-disabled baseline and limits the separately approved first cohort to a
1-10 percent canary.

After the canary observation window completes, use
`docs/production-canary-and-expansion.md`. It records explicit fail-closed
signal states and permits one separately approved expansion no higher than 25
percent. It does not authorize full traffic.

After the first expansion observation completes, use
`docs/production-progressive-expansion.md`. It records tamper-detecting evidence
and permits one separately approved step of at most 25 percentage points, with
an absolute cap of 50 percent. Full traffic remains outside this gate.
