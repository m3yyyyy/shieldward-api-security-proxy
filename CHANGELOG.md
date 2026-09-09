# Changelog

All notable changes to ShieldWard are documented here. Releases follow semantic
versioning.

## [1.0.0] - 2026-09-09

### Added

- Declarative YAML and TOML security policies compiled into canonical,
  Ed25519-signed bundles.
- A fail-closed Edge gateway with route matching, JWT verification, portable
  WAF rules, fixed-window rate limiting, body limits, and structured denials.
- Live policy synchronization with signature verification, trusted-key
  rotation, polling fallback, and last-known-good policy retention.
- Distributed Redis rate limiting with encrypted transport, bounded timeouts,
  secret-file credentials, and fail-closed dependency behavior.
- Request tracing, bounded security audit events, Prometheus metrics, readiness,
  and health endpoints.
- Upstream deadlines, global admission control, circuit breaking, graceful
  draining, and safe shutdown.
- Mutual TLS service identity between Edge and the control plane with exact
  SPIFFE authorization and last-known-good certificate reloads.
- Hardened Compose and Kubernetes deployments, vulnerability scanning,
  deterministic release archives, SPDX SBOMs, checksums, provenance, and
  artifact attestations.
- Production acceptance automation, failure-drill procedures, and a versioned
  release runbook.
