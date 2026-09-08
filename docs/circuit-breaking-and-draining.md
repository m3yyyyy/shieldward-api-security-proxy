# Circuit breaking and graceful draining

ShieldWard isolates an unhealthy upstream and drains active requests during a
process shutdown. These controls complement the upstream deadline and global
admission limit described in `docs/upstream-resilience.md`.

## Circuit behavior

Circuit state is isolated by upstream origin: scheme, hostname, and port.
Routes that share an origin share its health signal, while a failure at one
origin does not block another.

The following outcomes count as upstream failures:

- connection, DNS, and other fetch errors;
- expiration of the upstream deadline;
- upstream responses with status `500` through `599`.

A response below `500` resets the consecutive-failure count. Client
cancellation is neutral: it is forwarded upstream but does not count as an
upstream failure.

After the configured number of consecutive failures, the circuit opens.
Requests that reach an open circuit do not contact the upstream and receive:

```json
{"error":"upstream_circuit_open"}
```

The response uses HTTP status `503`, includes `Retry-After`, and is recorded in
the security audit log without exposing the upstream address. When the open
period expires, exactly one request becomes the half-open recovery probe.
Other requests remain rejected until that probe succeeds. A successful probe
closes the circuit; a failed probe opens it for another full period.

Runtime settings are:

- `SHIELDWARD_CIRCUIT_FAILURE_THRESHOLD`: consecutive failures required to
  open a circuit; default `5`, accepted range `1` through `100`;
- `SHIELDWARD_CIRCUIT_OPEN_MS`: open duration in milliseconds; default `30000`,
  accepted range `1` through `300000`;
- `SHIELDWARD_CIRCUIT_MAX_UPSTREAMS`: maximum retained upstream origins;
  default `1024`, accepted range `1` through `100000`.

If the retained-state limit contains only unavailable circuits, an unknown
origin is rejected rather than allowed without protection. This condition uses
the same fail-closed `upstream_circuit_open` response.

ShieldWard still performs no automatic retries. A circuit breaker limits
additional pressure; it does not make replaying writes safe.

## Shutdown sequence

On `SIGINT` or `SIGTERM`, Edge performs these steps:

1. Mark the gateway as draining so `/readyz` returns `503`.
2. Stop accepting new connections and reject any racing request with
   `503 gateway_draining`, `Connection: close`, and `Retry-After: 1`.
3. Wait for every admitted response body, including streams, to complete or be
   cancelled.
4. Close configuration synchronization and the rate-limit backend only after
   requests are idle.
5. Force-close connections and report an unsuccessful shutdown if the grace
   period expires.

`SHIELDWARD_SHUTDOWN_GRACE_MS` controls the internal grace period. Its default
is `10000`, with an accepted range of `1` through `120000` milliseconds. The
container or service-manager termination window must be longer than this value
so Edge has time to force-close and release dependencies before the operating
system kills it. The supplied Compose and Kubernetes windows are 15 and 20
seconds respectively.

`/healthz` remains healthy during draining because the process is still alive;
`/readyz` is the signal load balancers must use to remove the instance from
service.

## Metrics and tuning

Monitor:

- `shieldward_edge_upstream_circuits_unavailable`;
- `shieldward_edge_upstream_circuit_rejections_total`;
- `shieldward_edge_upstream_circuit_transitions_total`;
- `shieldward_edge_gateway_accepting_requests`;
- `shieldward_edge_gateway_drain_rejections_total`;
- `shieldward_edge_gateway_active_requests`.

Choose the failure threshold and open period using upstream error budgets and
recovery characteristics. Values that are too small can amplify brief faults;
values that are too large continue sending traffic to a known failing service.
Validate drain timing with the longest legitimate streaming response and keep
the external termination window safely above the observed drain time.
