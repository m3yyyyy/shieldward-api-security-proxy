# Changelog

All notable changes to ShieldWard are documented here. Releases follow semantic
versioning.

## [Unreleased]

### Added

- A generation-5 production assurance retention-renewal planning and approval
  gate that binds the exact retention-at-risk chain audit, derives baseline
  generation 6 and renewal sequence 5, and authorizes only the recorded
  external procedure without claiming that retention changed.
- A generation-5 production assurance custody chain audit that reconstructs
  sequences 13 through the selected recurring head, verifies every exact
  predecessor and digest without gaps or cycles, preserves the complete
  four-renewal lineage, and fails closed on unsafe audit evidence.
- Recurring generation-5 production assurance custody reviews that bind the
  exact passed sequence-13 predecessor, derive sequences 14 and 15 without gaps
  or resets, revalidate every archive control, and preserve the complete
  four-renewal lineage.
- Generation-5 production assurance custody-review evidence that binds the
  exact Chapter 79 baseline, records review sequence 13, revalidates every
  external archive control, and fails closed on late, missing, unsafe, unknown,
  stale, or altered evidence without scheduling the next review.
- A generation-5 production assurance custody baseline that accepts only the
  exact passed Chapter 78 renewal evidence, preserves the generation-4 audit
  head at sequence 12 and the complete four-renewal lineage, and derives review
  sequence 13 without scheduling or completing that review.
- Generation-4 production assurance retention-renewal execution evidence that
  binds the exact approved Chapter 77 plan, proves renewal sequence 4 and the
  generation-5 retention boundary from independent external observations, and
  fails closed on failed, unknown, stale, insufficient, or altered evidence.
- A generation-4 production assurance retention-renewal planning and approval
  gate that binds the exact retention-at-risk chain audit, derives baseline
  generation 5 and renewal sequence 4, and authorizes only the recorded
  external procedure without claiming that retention changed.
- A generation-4 production assurance custody chain audit that reconstructs
  sequences 10 through the selected recurring head, verifies every exact
  predecessor and digest without gaps or cycles, preserves the complete
  third-renewal lineage, and fails closed on unsafe audit evidence.
- Recurring generation-4 production assurance custody reviews that bind the
  exact latest passed predecessor, derive sequences 11 and later without gaps
  or resets, preserve the full inherited lineage, and fail closed on stale,
  altered, unknown, or unsafe archive evidence.
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
- A tamper-evident progressive recovery gate that observes the proven expansion
  boundary, limits the next step to 25 percentage points and 50 percent total
  traffic, requires a separate exact approval, and preserves rollback.
- Freshness-bound progressive recovery execution evidence that proves the exact
  externally enforced target, healthy verification, rollback to the previous
  boundary, and completed incident/change records without authorizing more traffic.
- A tamper-evident second recovery expansion gate that observes the proven
  progressive boundary, limits the next step to 25 percentage points and 75
  percent total traffic, requires separate exact approval, and preserves rollback.
- Freshness-bound second recovery expansion execution evidence that proves the
  exact externally enforced target, healthy verification, rollback to the
  progressive boundary, and completed incident/change records.
- A tamper-evident final recovery expansion gate that requires a healthy
  observation at the proven 75 percent boundary, separate exact approval for
  100 percent traffic, rollback to 75 percent, and no automatic mutation.
- Freshness-bound final recovery expansion execution evidence that proves
  externally enforced 100 percent traffic, healthy verification, rollback to
  75 percent, and completed records without automatically closing the incident.
- A tamper-evident recovery incident-closure gate that holds proven 100 percent
  traffic without mutation, requires sustained health and independent
  re-acceptance, preserves rollback to 75 percent, and authorizes only a
  separately approved external closure action.
- Freshness-bound recovery incident-closure execution evidence that proves the
  authoritative external incident and change records completed, verifies
  healthy post-closure monitoring and retained rollback, and treats unknown
  closure state as an open incident.
- Freshness-bound post-incident assurance and retrospective evidence that
  binds authoritative closure to sustained health, error-budget and security
  review, tracked corrective actions, retained rollback, and tamper detection.
- A freshness- and schedule-bound continuous assurance resumption bridge that
  binds passed post-incident evidence to complete monitoring, no drift, exact
  full traffic, retained rollback, and the existing periodic assurance loop.
- Scheduled production assurance continuity evidence that derives the first
  review deadline from resumption, detects late or missed execution, and
  requires current healthy, no-drift, full-traffic, and rollback proof.
- A tamper-evident recurring production assurance chain that derives every
  later review sequence and deadline from the exact previous passed artifact,
  rejects gaps or failed predecessors, and preserves full traffic and rollback.
- Immutable production assurance chain-audit checkpoints that inventory every
  retained review from sequence 1 through a recurring head, detect gaps,
  cycles, missing evidence, access failures, and lineage tampering.
- Tamper-evident production assurance evidence-custody records that bind an
  audited chain to external archive checksums, object lock, retention,
  encryption, least-privilege access, and restore verification.
- Scheduled production assurance custody-review evidence that revalidates the
  exact custody record, archive inventory and controls, remaining retention,
  and a next-review deadline inside the retention window.
- Recurring production assurance custody-review evidence that derives each
  sequence and deadline from the exact previous review while preserving the
  original custody checksum, chain digest, and retention boundary.
- Immutable production assurance custody chain-audit checkpoints that inventory
  every review from sequence 1 through a recurring head and independently
  verify root custody, retention, access, restore, and tamper evidence.
- Approval-gated production assurance retention-renewal plans that bind an
  exact failed custody audit to a minimum extension, next-review coverage,
  named authorities, and a tamper-evident independent approval.
- Production assurance retention-renewal execution evidence that binds the
  exact approved plan to observed immutable retention, complete inventory,
  encryption, least-privilege access, and independent restore verification.
- A tamper-evident renewed custody-review baseline that preserves the original
  custody and review-chain identity, binds the exact renewal evidence, and
  derives the next sequence and deadline without rewriting history.
- Freshness-bound renewed custody-review evidence that continues at the exact
  inherited sequence and deadline, revalidates archive controls, and binds a
  new review-link digest without resetting pre-renewal lineage.
- Recurring renewed custody-review evidence that accepts only the exact passed
  predecessor, derives every later sequence and deadline, and preserves the
  renewal baseline and original custody lineage across the continued chain.
- A renewed custody chain-audit checkpoint that inventories every post-renewal
  review from the baseline sequence through the exact recurring head while
  preserving renewal evidence and the pre-renewal lineage digest.
- Approval-gated subsequent retention-renewal plans that derive the next
  baseline generation and renewal sequence from an exact at-risk renewed-chain
  audit while preserving every original and renewed lineage digest.
- Freshness-bound subsequent retention-renewal execution evidence that proves
  renewal sequence 2 reached the approved boundary with immutable controls,
  complete inventory, least-privilege access, restore verification, and the
  unchanged original and renewed custody lineage before generation 3 begins.
- A tamper-evident generation-3 custody baseline that binds the exact second
  renewal evidence, preserves every original and renewed lineage digest, and
  derives review sequence 7 at the inherited deadline without resetting the
  review chain or extending retention locally.
- Freshness-bound generation-3 custody-review evidence that completes sequence
  7 at the inherited deadline, revalidates every external archive control, and
  preserves the full original and renewed lineage before sequence 8 may begin.
- Recurring generation-3 custody-review evidence that accepts only the exact
  latest passed predecessor, derives sequences 8 and later without gaps or
  resets, and preserves both renewals plus the complete custody lineage.
- A generation-3 custody chain-audit checkpoint that inventories sequences 7
  through the exact recurring head, rejects gaps, cycles, substitutions, and
  tampering, and preserves both renewals plus every earlier lineage digest.
- Approval-gated third retention-renewal plans that bind an exact at-risk
  generation-3 audit, derive baseline generation 4 and renewal sequence 3,
  and preserve both earlier renewals plus the complete custody lineage.
- Freshness-bound third retention-renewal execution evidence that binds the
  exact approved procedure, proves immutable archive controls and the full
  inherited lineage, and authorizes only creation of a generation-4 baseline.
- A tamper-evident generation-4 custody baseline that binds the exact third
  renewal evidence, preserves all prior baselines, renewals, and review-chain
  lineage, and derives sequence 10 without changing external retention.
- Freshness-bound generation-4 custody-review evidence that completes sequence
  10 at the inherited deadline, revalidates every external archive control,
  and preserves the full lineage before sequence 11 may continue.

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
