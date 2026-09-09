# Failure drills

Run drills in a non-production environment first. Announce the window, name an
operator and observer, capture the starting policy version and image digests,
and keep a tested rollback path. Stop immediately if traffic escapes the
intended environment, credentials appear in output, or the expected fail-closed
response is not observed.

## Control-plane outage

Expected behavior: Edge keeps its last verified policy, remains ready, records
configuration synchronization errors, and continues denying unauthorized
requests. A newly started Edge instance cannot become ready without obtaining a
verified bundle.

The automated Compose drill is:

```powershell
pwsh -NoProfile -File .\scripts\test-production-acceptance.ps1 -IncludeFailureDrills
```

In Kubernetes, scale or isolate only the test control plane, confirm existing
Edge pods still enforce the recorded policy version, then create a temporary
Edge pod and confirm it does not become ready. Restore the control plane and
wait for all deployments to report available before ending the drill.

## Rejected policy update

Expected behavior: an invalid policy never replaces the active signed bundle,
the rejection counter increases, and Edge continues enforcing the previous
version.

1. Record `/readyz` and `shieldward_control_plane_policy_reload_total`.
2. Replace the test policy with a copy containing an invalid route or rate
   limit; never edit the only recoverable copy.
3. Wait longer than the policy watch interval.
4. Confirm the rejection counter increased and the Edge policy version did not
   change.
5. Restore the validated policy and confirm a successful reload.

## Invalid certificate rotation

Expected behavior: malformed, mismatched, expired, or wrongly authorized
replacement material is rejected while the active TLS sessions and
last-known-good identity continue working.

Follow the staging and atomic replacement procedure in
`docs/mutual-tls-and-certificate-rotation.md`. Never truncate an active secret
in place. During the drill, present a deliberately invalid candidate through
the secret delivery mechanism, confirm the appropriate
`shieldward_*_tls_reload_total{result="rejected"}` counter increases, and verify
that readiness and policy retrieval remain successful. Restore valid material
before testing a successful rotation.

## Redis rate-limit outage

This drill applies only when the distributed backend is enabled. Expected
behavior: a route requiring a rate-limit decision fails closed with
`503 rate_limiter_unavailable`; readiness reports not ready while Redis is
unavailable; unrelated unauthenticated requests remain denied.

Isolate the test Redis service, verify the failure and metrics, restore Redis,
and wait for readiness before resuming traffic. Do not switch to in-memory
limiting during an outage because that silently weakens cross-instance limits.

## Upstream outage and circuit recovery

Expected behavior: connection failures become `502`, deadlines become `504`,
and repeated failures open the circuit. Requests rejected by an open circuit
receive `503 upstream_circuit_open` with `Retry-After` and do not contact the
upstream. Exactly one half-open probe is allowed after the configured interval.

Isolate one test upstream without changing other destinations, send only the
minimum traffic required to reach the configured threshold, then restore it.
Confirm the half-open probe closes the circuit and that another upstream was
not affected. Never use non-idempotent production requests as probes.

## Graceful drain

Expected behavior: readiness becomes `503`, new requests receive
`503 gateway_draining`, active response bodies finish within the grace period,
and dependencies close only after requests are idle.

Run the drill with a controlled long response shorter than the configured grace
period. Send `SIGTERM`, observe removal from load balancing, and confirm the
request completes. Repeat with a response longer than the grace period and
confirm a forced shutdown is reported as unsuccessful. Keep the platform
termination window longer than `SHIELDWARD_SHUTDOWN_GRACE_MS`.

## Evidence and closure

For every drill, retain timestamps, policy version, image digest, relevant
bounded metrics, sanitized logs, observed status codes, recovery time, and the
operator who approved closure. Open a tracked remediation for every unexpected
result; do not reinterpret a failed drill as accepted risk during the release
window.
