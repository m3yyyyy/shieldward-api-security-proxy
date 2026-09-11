# Changelog

All notable changes to ShieldWard are documented here. Releases follow semantic
versioning.

## [Unreleased]

### Added

- Guarded, digest-pinned Kubernetes staging overlays with exact-context rollout
  checks, fail-closed acceptance probes, an optional control-plane outage drill,
  sanitized evidence capture, and digest-based rollback guidance.
- Tamper-evident production promotion plans with explicit approval records,
  exact-context read-only preflights, immutable rollback baselines, and a
  bounded observation and traffic-expansion procedure.
- A first-production installation gate with verified staging evidence,
  traffic-disabled approval, an exact-context empty-baseline preflight, and an
  approved removal path that does not invent a previous release.
- Sanitized production baseline evidence and a separate, tamper-detecting
  initial traffic plan limited to a fresh, explicitly approved 1-10 percent
  canary with disable-before-removal guidance.
- Tamper-detecting initial canary observation evidence with fail-closed signal
  states and a separately approved first expansion capped at 25 percent.
- Tamper-detecting first-expansion evidence and a separately approved
  progressive step limited to 25 percentage points and 50 percent total traffic.
- Tamper-detecting progressive expansion evidence and a separately approved
  second step limited to 25 percentage points and 75 percent total traffic.
- Tamper-detecting 75 percent observation evidence and a separately approved,
  exact final expansion from 75 to 100 percent with rollback to the prior cohort.
- Tamper-detecting full-traffic observation evidence and a fail-closed
  steady-state acceptance gate that requires externally enforced 100 percent
  traffic, complete healthy signals, and an explicit rollback path.
- Freshness-bound continuous production assurance evidence with explicit
  image, policy, configuration, identity, certificate, and routing drift
  states plus mandatory re-acceptance for material drift.
- Tamper-evident production incident response plans that bind failed or unknown
  assurance evidence to an explicit action, recorded authority, bounded
  deadline, and approval without mutating production.
- Freshness-bound production incident containment evidence that proves exact
  hold-at-100, rollback-to-75, or disable-to-zero response enforcement before
  recovery can begin.
- Tamper-evident production incident recovery plans with separate change
  approval, fail-closed readiness checks, bounded zero-to-canary restoration,
  exact 75-to-100 recovery, and rollback to the contained boundary.
- Freshness-bound production incident recovery execution evidence that proves
  the exact externally enforced target, healthy verification, rollback
  readiness, and completed incident/change records without closing incidents.
- Tamper-evident recovery canary observation and a separately approved
  re-expansion capped at 25 percent, with rollback to the proven canary or
  emergency disable-to-zero and no automatic production mutation.
- Freshness-bound recovery expansion execution evidence that proves the exact
  externally enforced target, healthy error-budget and operational signals,
  ready rollback, and updated incident/change records.

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
