# Transport security

ShieldWard requires encrypted transport whenever a service communicates beyond the local machine. Plain HTTP is accepted only for explicit loopback hosts so local development can continue without certificates.

## Edge listener

The Edge listener uses HTTPS when both environment variables are configured:

- `SHIELDWARD_TLS_CERT_FILE`: absolute or working-directory-relative path to a PEM certificate chain.
- `SHIELDWARD_TLS_KEY_FILE`: absolute or working-directory-relative path to its unencrypted PEM private key.

Both values are required together. Binding `HOST` to a non-loopback address without them fails startup. The minimum accepted TLS version is TLS 1.2.

Example:

```powershell
$env:HOST = "0.0.0.0"
$env:SHIELDWARD_TLS_CERT_FILE = "C:\ShieldWard\secrets\edge-cert.pem"
$env:SHIELDWARD_TLS_KEY_FILE = "C:\ShieldWard\secrets\edge-key.pem"
npm.cmd --prefix .\edge run start
```

Keep private keys outside the repository and restrict their filesystem permissions. HTTPS responses include `Strict-Transport-Security: max-age=31536000`. All responses include `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`.

## Control-plane listener

The control plane uses HTTPS when both `-tls-cert` and `-tls-key` are supplied. A non-loopback `-listen` address is rejected without them.

```powershell
.\bin\shieldwardd.exe serve `
  -policy .\examples\policies\basic.yaml `
  -listen 0.0.0.0:18080 `
  -tls-cert C:\ShieldWard\secrets\control-cert.pem `
  -tls-key C:\ShieldWard\secrets\control-key.pem
```

Configure the Edge process with the matching HTTPS URL:

```powershell
$env:CONTROL_PLANE_URL = "https://control.example:18080"
```

For a private certificate authority, configure Node.js to trust the CA before starting the Edge process, for example with `NODE_EXTRA_CA_CERTS`. Do not disable certificate verification.

## Upstream services

Policy upstream URLs must use HTTPS unless they target a loopback host. The Go policy validator, Edge bundle parser, and proxy all enforce this rule independently. JWT issuer and JWKS URLs always require HTTPS.
