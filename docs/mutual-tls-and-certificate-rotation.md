# Mutual TLS service identity and certificate rotation

ShieldWard authenticates the Edge service to the control plane with mutual TLS.
The control plane verifies the client certificate chain and authorizes one exact
SPIFFE URI SAN. Requests to `/v1/bundle` and `/v1/events` without a verified
client identity receive HTTP 401. Health and readiness endpoints remain
available over server-authenticated TLS so container and Kubernetes probes do
not need an application identity.

The default deployment identity is:

```text
spiffe://shieldward.local/edge
```

DNS names and certificate common names are not accepted as client identities.
The exact URI SAN comparison prevents a certificate issued for another service
by the same CA from gaining access to signed configuration.

## Control-plane configuration

Configure the HTTPS listener and client authorization together:

```powershell
.\bin\shieldwardd.exe serve `
  -policy .\examples\policies\basic.yaml `
  -listen 0.0.0.0:18080 `
  -tls-cert C:\ShieldWard\secrets\control-plane-cert.pem `
  -tls-key C:\ShieldWard\secrets\control-plane-key.pem `
  -client-ca C:\ShieldWard\secrets\edge-client-ca-bundle.pem `
  -client-identity spiffe://shieldward.local/edge `
  -tls-reload-interval 30s
```

`-client-ca` and `-client-identity` are required together. Client
authentication cannot be enabled on a cleartext listener. The reload interval
must be between one second and ten minutes.

## Edge configuration

An HTTPS control-plane URL requires all three outbound mutual TLS files:

- `SHIELDWARD_CONTROL_PLANE_CA_FILE`: CA bundle used only to verify the control
  plane.
- `SHIELDWARD_CONTROL_PLANE_CLIENT_CERT_FILE`: Edge client certificate chain.
- `SHIELDWARD_CONTROL_PLANE_CLIENT_KEY_FILE`: unencrypted private key matching
  the client certificate.
- `SHIELDWARD_TLS_RELOAD_INTERVAL_MS`: listener and control-plane client reload
  interval; defaults to 30,000 milliseconds.

The Edge does not depend on the process-wide `NODE_EXTRA_CA_CERTS` setting for
this trust decision. Each configuration request uses the explicitly loaded CA,
client certificate, and private key and always verifies the control-plane DNS
name from `CONTROL_PLANE_URL`.

## Rotation behavior

Both services periodically read their TLS files. A candidate set is parsed and
validated as one unit before it becomes active. Empty, oversized, malformed,
expired, or mismatched certificate and key files are rejected. The active
last-known-good material remains in use and a bounded reload-failure metric is
incremented. File contents and certificate subjects are not logged.

New TLS connections use the newest accepted material. Existing connections,
including an active server-sent event stream, may retain the previous identity
until they close. The normal configuration polling and SSE reconnect paths
therefore adopt a rotated client certificate without restarting the Edge.

### CA rollover without an outage

Do not replace a CA and every leaf certificate in one step. Use an overlap:

1. Add the new CA certificate to the existing CA bundle on both services.
2. Wait longer than the configured reload interval and confirm successful
   reload metrics.
3. Replace the control-plane server certificate and Edge client certificate,
   each with its matching private key.
4. Confirm new connections succeed and both services remain ready.
5. Remove the retired CA from both bundles after all old leaf certificates and
   long-lived connections have expired or closed.

Kubernetes Secret volumes are mounted as directories rather than `subPath`
files so projected Secret updates can become visible to the reloaders. A secret
manager should update the complete certificate/key set and preserve the CA
overlap. Private keys must never be stored in ConfigMaps, images, logs, or the
repository.

## Local development certificates

The local generator creates separate server and client keys. The Edge client
certificate has the client-authentication extended key usage and the exact
SPIFFE URI SAN expected by the supplied deployment files:

```powershell
pwsh -NoProfile -File .\scripts\new-container-tls.ps1
```

Use `-Force` only for an intentional local reset. The generated CA is for local
development and must not be installed as a production trust anchor.

## Metrics and alerts

The Edge exports
`shieldward_edge_tls_reload_total{role,result}` for the bounded roles
`listener` and `control_plane_client`. The control plane exports
`shieldward_control_plane_tls_reload_total{result}`. Alert when the `rejected`
counter increases or when a planned rotation does not produce an `updated`
event within two reload intervals.
