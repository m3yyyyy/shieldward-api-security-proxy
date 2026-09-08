# Distributed rate limiting

ShieldWard uses a bounded in-memory fixed-window rate limiter by default. That
mode is safe for one Edge process, but each replica has an independent counter.
Deployments that run multiple Edge replicas can select the Redis backend to
enforce one limit across all replicas.

The Redis backend executes one atomic Lua script per check. It uses the Redis
server clock to align windows, preventing Edge clock differences from creating
different boundaries. Redis keys contain a SHA-256 digest of the route and
identity instead of route IDs, client IP addresses, or JWT subjects.

## Configuration

Set `SHIELDWARD_RATE_LIMIT_BACKEND=redis` and provide:

- `SHIELDWARD_REDIS_URL`: a `rediss://` URL. Cleartext `redis://` is accepted
  only for a loopback host, including the isolated CI integration test.
- `SHIELDWARD_REDIS_USERNAME`: optional Redis ACL username.
- `SHIELDWARD_REDIS_PASSWORD_FILE`: optional path to a mounted password file.
  `SHIELDWARD_REDIS_PASSWORD` is deliberately rejected so credentials are not
  placed directly in environment variables or URLs.
- `SHIELDWARD_REDIS_CA_FILE`: optional private certificate-authority bundle for
  a `rediss://` endpoint.
- `SHIELDWARD_REDIS_PREFIX`: optional safe key prefix; the default is
  `shieldward:rate-limit:v1`.
- `SHIELDWARD_REDIS_CONNECT_TIMEOUT_MS`: connection timeout from 1 through
  30000 milliseconds; the default is 3000.
- `SHIELDWARD_REDIS_COMMAND_TIMEOUT_MS`: per-command timeout from 1 through
  30000 milliseconds; the default is 1000.

Remote cleartext connections, embedded URL credentials, query strings,
fragments, multiline password files, and invalid prefixes are rejected during
startup. Redis rate-limit windows must resolve to whole milliseconds.

The client disables its offline queue and bounds the command queue. Edge will
not start unless it can connect and receive `PONG`. If the connection becomes
unavailable later, protected requests fail closed with HTTP 503 and
`rate_limiter_unavailable`; `/healthz` remains live while `/readyz` returns 503.

## Local integration test

Start an isolated Redis container bound only to loopback:

```powershell
docker run --detach --rm --name shieldward-redis-test `
  --publish 127.0.0.1:6379:6379 `
  redis:8.10.1-alpine@sha256:becdda6c7f4b3fb42e42fd7f120bbf5c54c4caaaf16f26da24e4563d2c1f0576
```

Run the two-client integration test from the repository root:

```powershell
$env:TEST_REDIS_URL = 'redis://127.0.0.1:6379'
npm.cmd --prefix .\edge test -- redis-rate-limit.integration.test.ts
Remove-Item Env:TEST_REDIS_URL
docker stop shieldward-redis-test
```

The regular test suite skips this integration test when `TEST_REDIS_URL` is
absent. Continuous integration runs it against an isolated, digest-pinned Redis
service.

## Kubernetes overlay

The base Kubernetes deployment retains one replica and the in-memory backend. The
`deploy/kubernetes/redis-rate-limit` overlay configures the two Edge replicas
for a TLS Redis service named `shieldward-redis` and adds a narrowly selected
NetworkPolicy rule for pods carrying these labels:

```yaml
app.kubernetes.io/name: shieldward
app.kubernetes.io/component: rate-limit-store
```

Provision that service with TLS and authentication before applying the overlay.
Add the password and its certificate authority to the existing Edge secret:

```powershell
kubectl -n shieldward create secret generic shieldward-edge-credentials `
  --from-file=control-plane-public.pem=.\.shieldward\public.pem `
  --from-file=control-plane-ca.pem=C:\secure\control-plane-ca.pem `
  --from-file=tls-cert.pem=C:\secure\edge-cert.pem `
  --from-file=tls-key.pem=C:\secure\edge-key.pem `
  --from-file=redis-password=C:\secure\redis-password `
  --from-file=redis-ca.pem=C:\secure\redis-ca.pem

kubectl apply -k .\deploy\kubernetes\redis-rate-limit
```

Replace the example service name, port, secret paths, and NetworkPolicy target
to match the real Redis operator or managed service. An external managed Redis
endpoint also requires an environment-specific egress rule; do not add a broad
egress exception merely to make it reachable.

## Metrics and alerts

The loopback-only Edge metrics endpoint includes:

- `shieldward_edge_rate_limiter_ready`;
- `shieldward_edge_rate_limit_checks_total{backend,result}` where backend is
  `memory` or `redis`, and result is `allowed`, `limited`, or `error`.

Alert when Redis-mode readiness remains zero or the `error` result increases.
These labels are bounded and never include request identities or Redis URLs.
