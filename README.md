# ShieldWard API security proxy

ShieldWard is a fail-closed API security gateway with a signed policy control
plane. The Go control plane validates and signs declarative policies. The Node.js
Edge runtime verifies those bundles before enforcing route matching, JWT
validation, WAF rules, rate limits, request limits, upstream deadlines, circuit
breaking, and graceful draining.

The supplied deployment uses mutual TLS between Edge and the control plane,
requires an exact SPIFFE service identity, reloads certificates without dropping
the last-known-good identity, and runs both containers as non-root users with
read-only filesystems.

## Verify the source checkout

Run these commands from the repository root with Go, Node.js, npm, and
PowerShell 7 installed:

```powershell
go test ./...
go vet ./...
npm.cmd --prefix .\edge ci
npm.cmd --prefix .\edge test
npm.cmd --prefix .\edge run typecheck
npm.cmd --prefix .\edge run build
pwsh -NoProfile -File .\scripts\check-repository.ps1
pwsh -NoProfile -File .\scripts\check-release-readiness.ps1
```

## Run the hardened local stack

Docker Engine with Compose v2 is required:

```powershell
go run ./cmd/shieldwardd keygen
pwsh -NoProfile -File .\scripts\new-container-tls.ps1
docker compose up --build --detach --wait --wait-timeout 180
pwsh -NoProfile -File .\scripts\test-production-acceptance.ps1 -IncludeFailureDrills
docker compose down --volumes --remove-orphans
```

All generated signing and TLS material stays in the ignored `.shieldward`
directory. It is for local testing only.

## Operational documentation

- [Staging rollout and rollback](docs/staging-rollout.md)
- [Initial production installation gate](docs/initial-production-installation.md)
- [Production baseline and initial traffic gate](docs/production-baseline-and-traffic.md)
- [Production canary evidence and first expansion gate](docs/production-canary-and-expansion.md)
- [Production first-expansion evidence and progressive gate](docs/production-progressive-expansion.md)
- [Production progressive evidence and second expansion gate](docs/production-second-expansion.md)
- [Production second-expansion evidence and final expansion gate](docs/production-final-expansion.md)
- [Production full-traffic evidence and steady-state acceptance](docs/production-steady-state.md)
- [Continuous production assurance and drift detection](docs/production-assurance.md)
- [Production incident response planning](docs/production-incident-response.md)
- [Production incident containment evidence](docs/production-incident-containment.md)
- [Production incident recovery planning](docs/production-incident-recovery.md)
- [Production incident recovery execution evidence](docs/production-incident-recovery-evidence.md)
- [Production recovery canary observation and expansion gate](docs/production-incident-recovery-expansion.md)
- [Production recovery expansion execution evidence](docs/production-incident-recovery-expansion-evidence.md)
- [Production recovery progressive observation and expansion gate](docs/production-incident-recovery-progressive.md)
- [Production recovery progressive expansion execution evidence](docs/production-incident-recovery-progressive-evidence.md)
- [Production recovery second expansion observation and gate](docs/production-incident-recovery-second-expansion.md)
- [Production recovery second expansion execution evidence](docs/production-incident-recovery-second-expansion-evidence.md)
- [Production recovery final expansion observation and gate](docs/production-incident-recovery-final-expansion.md)
- [Production recovery final expansion execution evidence](docs/production-incident-recovery-final-expansion-evidence.md)
- [Production recovery re-acceptance and incident-closure gate](docs/production-incident-recovery-closure.md)
- [Production recovery incident-closure execution evidence](docs/production-incident-recovery-closure-evidence.md)
- [Production post-incident assurance and retrospective evidence](docs/production-post-incident-assurance.md)
- [Continuous production assurance resumption evidence](docs/production-assurance-resumption.md)
- [Scheduled production assurance continuity evidence](docs/production-assurance-continuity.md)
- [Recurring production assurance continuity evidence](docs/production-assurance-recurring.md)
- [Production assurance chain audit evidence](docs/production-assurance-chain-audit.md)
- [Production assurance evidence custody](docs/production-assurance-evidence-custody.md)
- [Scheduled production assurance custody review](docs/production-assurance-custody-review.md)
- [Recurring production assurance custody reviews](docs/production-assurance-custody-recurring.md)
- [Production assurance custody chain audit](docs/production-assurance-custody-chain-audit.md)
- [Production assurance retention-renewal plan](docs/production-assurance-retention-renewal.md)
- [Production assurance retention-renewal evidence](docs/production-assurance-retention-renewal-evidence.md)
- [Production assurance renewed custody-review baseline](docs/production-assurance-renewed-custody-baseline.md)
- [Production assurance renewed custody-review evidence](docs/production-assurance-renewed-custody-review.md)
- [Recurring production assurance renewed custody reviews](docs/production-assurance-renewed-custody-recurring.md)
- [Renewed production assurance custody chain audit](docs/production-assurance-renewed-custody-chain-audit.md)
- [Renewed production assurance retention-renewal plan](docs/production-assurance-renewed-retention-renewal.md)
- [Renewed production assurance retention-renewal evidence](docs/production-assurance-renewed-retention-renewal-evidence.md)
- [Next renewed production assurance custody baseline](docs/production-assurance-next-renewed-custody-baseline.md)
- [Next renewed production assurance custody review](docs/production-assurance-next-renewed-custody-review.md)
- [Recurring next-renewed production assurance custody reviews](docs/production-assurance-next-renewed-custody-recurring.md)
- [Next renewed production assurance custody chain audit](docs/production-assurance-next-renewed-custody-chain-audit.md)
- [Next renewed production assurance retention-renewal plan](docs/production-assurance-next-renewed-retention-renewal.md)
- [Next renewed production assurance retention-renewal evidence](docs/production-assurance-next-renewed-retention-renewal-evidence.md)
- [Generation-4 production assurance custody baseline](docs/production-assurance-generation-4-custody-baseline.md)
- [Generation-4 production assurance custody review](docs/production-assurance-generation-4-custody-review.md)
- [Recurring generation-4 production assurance custody reviews](docs/production-assurance-generation-4-custody-recurring.md)
- [Generation-4 production assurance custody chain audit](docs/production-assurance-generation-4-custody-chain-audit.md)
- [Generation-4 production assurance retention-renewal plan](docs/production-assurance-generation-4-retention-renewal.md)
- [Generation-4 production assurance retention-renewal evidence](docs/production-assurance-generation-4-retention-renewal-evidence.md)
- [Generation-5 production assurance custody baseline](docs/production-assurance-generation-5-custody-baseline.md)
- [Generation-5 production assurance custody review](docs/production-assurance-generation-5-custody-review.md)
- [Recurring generation-5 production assurance custody reviews](docs/production-assurance-generation-5-custody-recurring.md)
- [Generation-5 production assurance custody chain audit](docs/production-assurance-generation-5-custody-chain-audit.md)
- [Generation-5 production assurance retention-renewal plan](docs/production-assurance-generation-5-retention-renewal.md)
- [Generation-5 production assurance retention-renewal evidence](docs/production-assurance-generation-5-retention-renewal-evidence.md)
- [Generation-6 production assurance custody baseline](docs/production-assurance-generation-6-custody-baseline.md)
- [Generation-6 production assurance custody review](docs/production-assurance-generation-6-custody-review.md)
- [Recurring generation-6 production assurance custody reviews](docs/production-assurance-generation-6-custody-recurring.md)
- [Production promotion decision gate](docs/production-promotion.md)
- [Production acceptance](docs/production-acceptance.md)
- [Failure drills](docs/failure-drills.md)
- [Release runbook](docs/release-runbook.md)
- [Container and Kubernetes deployment](docs/containers.md)
- [Mutual TLS and certificate rotation](docs/mutual-tls-and-certificate-rotation.md)
- [Observability](docs/observability.md)
- [Supply-chain security](docs/supply-chain.md)
- [Security reporting](SECURITY.md)

The example policy is not a production identity configuration. Replace its
issuer, JWKS endpoint, audiences, upstreams, trust anchors, capacity limits, and
network policy with values approved for the target environment.
