# Upstream resilience and overload protection

ShieldWard places a deadline around every upstream request and bounds the
number of requests admitted to the gateway. These controls prevent a slow or
stalled upstream from consuming Edge capacity without limit.

## Runtime settings

- `SHIELDWARD_UPSTREAM_TIMEOUT_MS` sets the upstream deadline in milliseconds.
  The default is `10000`; accepted values are from `1` through `120000`.
- `SHIELDWARD_MAX_IN_FLIGHT_REQUESTS` sets the number of requests one Edge
  process may admit concurrently. The default is `1024`; accepted values are
  from `1` through `100000`.

Invalid values stop Edge during startup instead of silently disabling either
protection.

The deadline starts when Edge begins the upstream fetch. If it expires before
the upstream returns response headers, Edge returns:

```json
{"error":"upstream_timeout"}
```

with HTTP status `504`. If the deadline expires after headers were returned,
the response stream terminates because its status can no longer be changed.
Client cancellation remains distinct and is forwarded to the upstream.

When the in-flight limit is full, Edge does not evaluate policy or contact the
upstream. It returns:

```json
{"error":"gateway_overloaded"}
```

with HTTP status `503` and `Retry-After: 1`. An admitted request holds its slot
until its response body is completely consumed or cancelled. This includes
streaming responses, preventing open streams from bypassing the limit.

## Retry boundary

ShieldWard does not automatically retry failed upstream requests. Retrying a
write can duplicate side effects when an upstream completed the operation but
its response was lost. Clients may retry requests only when their own protocol
defines the operation as safe or uses a verified idempotency key.

## Capacity tuning

Set the deadline above normal high-percentile upstream latency while keeping it
below the caller's total timeout. Set the in-flight limit from load-test data,
available memory, upstream concurrency, and the number of Edge replicas. Make
changes gradually and observe:

- `shieldward_edge_gateway_active_requests`;
- `shieldward_edge_gateway_overload_rejections_total`;
- gateway responses with status `502`, `503`, and `504`;
- upstream latency and saturation.

Alert when active requests remain close to the configured maximum, overload
rejections begin increasing, or upstream timeouts exceed the service's error
budget. Increasing the limit without fixing a saturated upstream usually
increases latency and memory pressure rather than capacity.

Circuit breaking and process draining build on these limits. See
`docs/circuit-breaking-and-draining.md` for failure isolation, recovery probes,
and the shutdown sequence.
