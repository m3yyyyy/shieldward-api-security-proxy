# Operational metrics

ShieldWard exposes Prometheus-compatible operational metrics from both the
control plane and the edge service at `GET /metrics`.

The endpoint is intentionally restricted to direct loopback clients. A remote
request receives `404 route_not_found`, even when the main listener accepts
remote TLS traffic. Run a Prometheus agent or another collector on the same
host and forward telemetry through the collector's authenticated, encrypted
connection.

Do not place a public reverse-proxy route in front of `/metrics`. The endpoint
has `Cache-Control: no-store` and is intended for operational collection, not
public diagnostics.

## Edge metrics

The edge service reports:

- process start time and uptime;
- whether a verified policy is ready;
- whether the configured rate-limit backend is ready;
- current admitted requests that have not completed or been cancelled;
- cumulative requests rejected at the in-flight admission limit;
- whether the gateway is still accepting new requests and drain rejections;
- unavailable upstream circuit count, circuit rejections, and transitions;
- age of the active verified policy;
- gateway request counts by the bounded `outcome` and `status` labels;
- request-duration count and sum by outcome;
- configuration refresh counts for `updated` and `unchanged`;
- a separate configuration synchronization error counter;
- accepted and rejected TLS material reloads by bounded listener or
  control-plane-client role;
- rate-limit checks by the bounded backend and result labels;
- successful local metric scrapes.

It deliberately does not use paths, route identifiers, request IDs, client IP
addresses, headers, query strings, tokens, or body content as labels.

## Control-plane metrics

The control plane reports:

- process start time and uptime;
- whether a signed policy bundle is ready;
- HTTP request counts by a fixed route class and status;
- successful and rejected policy reload counts;
- successful and rejected TLS material reload counts;
- active server-sent event connections;
- successful local metric scrapes.

Unknown URLs are grouped under the fixed `other` route label, preventing an
attacker from creating unbounded metric cardinality with arbitrary paths.

## Local inspection

With the default local listeners running, inspect the endpoints in PowerShell:

```powershell
Invoke-WebRequest "http://127.0.0.1:18080/metrics" | Select-Object -ExpandProperty Content
Invoke-WebRequest "http://127.0.0.1:8787/metrics" | Select-Object -ExpandProperty Content
```

For a local development certificate, use the HTTPS listener URLs and
`-SkipCertificateCheck` only for that short-lived local test. Production
collectors must validate the server certificate normally.

## Suggested alerts

Alert when any of these conditions persist:

- either readiness gauge is `0`;
- Redis rate-limit errors increase when the distributed backend is enabled;
- `shieldward_edge_policy_age_seconds` exceeds the expected reload interval;
- configuration refresh or policy reload rejection counters increase;
- either TLS reload `rejected` counter increases, or a planned rotation does
  not produce an `updated` event;
- the edge `error` outcome rate or upstream `502` response rate increases;
- upstream `504` responses or
  `shieldward_edge_gateway_overload_rejections_total` increase;
- `shieldward_edge_gateway_active_requests` remains near its configured
  maximum;
- `shieldward_edge_upstream_circuits_unavailable` remains above `0` or circuit
  rejections increase;
- `shieldward_edge_gateway_accepting_requests` unexpectedly becomes `0` outside
  a planned rollout;
- no metric scrapes arrive within the collector's expected interval.

Counter increases should be evaluated with a rate or increase function rather
than alerting on their absolute lifetime value.
