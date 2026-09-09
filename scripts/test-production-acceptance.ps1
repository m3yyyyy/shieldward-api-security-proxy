[CmdletBinding()]
param(
    [switch]$IncludeFailureDrills
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$certificateAuthorityPath = Join-Path $repoRoot '.shieldward/containers/ca.pem'
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temporaryDirectory = Join-Path $temporaryRoot "shieldward-acceptance-$([Guid]::NewGuid().ToString('N'))"
$curlCommand = if ($IsWindows) { 'curl.exe' } else { 'curl' }

function Invoke-Compose {
    param(
        [Parameter(Mandatory)]
        [string[]]$ComposeArguments
    )

    $output = @(& docker compose @ComposeArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($ComposeArguments -join ' ') failed:`n$($output -join "`n")"
    }
    return $output
}

function Invoke-EdgeRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $identifier = [Guid]::NewGuid().ToString('N')
    $bodyPath = Join-Path $temporaryDirectory "$identifier.body"
    $headerPath = Join-Path $temporaryDirectory "$identifier.headers"
    $url = "https://127.0.0.1:8787$Path"

    $statusText = (& $curlCommand `
        --silent `
        --show-error `
        --output $bodyPath `
        --dump-header $headerPath `
        --write-out '%{http_code}' `
        --cacert $certificateAuthorityPath `
        $url 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Request to $url failed: $statusText"
    }
    if ($statusText -notmatch '^[0-9]{3}$') {
        throw "Request to $url returned an invalid status value '$statusText'."
    }

    return [pscustomobject]@{
        Status = [int]$statusText
        Body = [System.IO.File]::ReadAllText($bodyPath)
        Headers = [System.IO.File]::ReadAllText($headerPath)
    }
}

function Assert-Status {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Response,
        [Parameter(Mandatory)]
        [int]$Expected,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if ($Response.Status -ne $Expected) {
        throw "$Description returned HTTP $($Response.Status); expected $Expected. Body: $($Response.Body)"
    }
}

function Assert-JsonValue {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Response,
        [Parameter(Mandatory)]
        [string]$Property,
        [Parameter(Mandatory)]
        [string]$Expected,
        [Parameter(Mandatory)]
        [string]$Description
    )

    $json = $Response.Body | ConvertFrom-Json
    $actualProperty = $json.PSObject.Properties[$Property]
    if ($null -eq $actualProperty -or [string]$actualProperty.Value -ne $Expected) {
        throw "$Description did not report $Property='$Expected'. Body: $($Response.Body)"
    }
}

function Assert-SecurityHeaders {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Response,
        [Parameter(Mandatory)]
        [string]$Description
    )

    foreach ($pattern in @(
        '(?im)^x-content-type-options:\s*nosniff\s*$'
        '(?im)^referrer-policy:\s*no-referrer\s*$'
        '(?im)^strict-transport-security:\s*max-age=31536000\s*$'
        '(?im)^cache-control:\s*no-store\s*$'
    )) {
        if ($Response.Headers -notmatch $pattern) {
            throw "$Description is missing an expected security header matching '$pattern'."
        }
    }
}

function Test-EdgeFailClosed {
    param(
        [Parameter(Mandatory)]
        [string]$Phase
    )

    $ready = Invoke-EdgeRequest -Path '/readyz'
    Assert-Status -Response $ready -Expected 200 -Description "$Phase readiness"
    Assert-JsonValue -Response $ready -Property 'status' -Expected 'ready' -Description "$Phase readiness"
    $readyJson = $ready.Body | ConvertFrom-Json
    if ([string]$readyJson.policyVersion -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Phase readiness returned an invalid policy version. Body: $($ready.Body)"
    }
    Assert-SecurityHeaders -Response $ready -Description "$Phase readiness"

    $unknown = Invoke-EdgeRequest -Path '/unknown'
    Assert-Status -Response $unknown -Expected 403 -Description "$Phase default-deny request"
    Assert-JsonValue -Response $unknown -Property 'error' -Expected 'default_deny' -Description "$Phase default-deny request"
    Assert-SecurityHeaders -Response $unknown -Description "$Phase default-deny request"

    $protected = Invoke-EdgeRequest -Path '/v1/orders/42'
    Assert-Status -Response $protected -Expected 401 -Description "$Phase protected-route request"
    Assert-JsonValue -Response $protected -Property 'error' -Expected 'jwt_invalid' -Description "$Phase protected-route request"
    Assert-SecurityHeaders -Response $protected -Description "$Phase protected-route request"
}

function Test-ControlPlaneIdentityGate {
    $identityProbe = @'
import { readFileSync } from 'node:fs';
import { request } from 'node:https';

const send = (includeIdentity) => new Promise((resolve, reject) => {
  const options = {
    hostname: 'control-plane',
    port: 18080,
    path: '/v1/bundle',
    method: 'GET',
    ca: readFileSync('/run/secrets/control-plane-ca.pem'),
    minVersion: 'TLSv1.2',
    rejectUnauthorized: true,
    agent: false,
  };
  if (includeIdentity) {
    options.cert = readFileSync('/run/secrets/control-plane-client-cert.pem');
    options.key = readFileSync('/run/secrets/control-plane-client-key.pem');
  }
  const outgoing = request(options, (incoming) => {
    const chunks = [];
    incoming.on('data', (chunk) => chunks.push(chunk));
    incoming.on('end', () => resolve({
      status: incoming.statusCode,
      body: Buffer.concat(chunks).toString('utf8'),
    }));
  });
  outgoing.on('error', reject);
  outgoing.end();
});

const anonymous = await send(false);
if (anonymous.status !== 401) {
  throw new Error(`anonymous control-plane request returned ${anonymous.status}`);
}
const identified = await send(true);
if (identified.status !== 200) {
  throw new Error(`identified control-plane request returned ${identified.status}: ${identified.body}`);
}
const envelope = JSON.parse(identified.body);
if (!/^sha256:[0-9a-f]{64}$/.test(envelope?.bundle?.version ?? '')) {
  throw new Error('identified control-plane response has no valid bundle version');
}
console.log('Control-plane identity gate accepted only the configured service identity.');
'@

    $output = @(& docker compose exec -T edge node --input-type=module --eval $identityProbe 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Control-plane identity acceptance test failed:`n$($output -join "`n")"
    }
    Write-Host ($output -join "`n")
}

function Wait-ControlPlane {
    for ($attempt = 1; $attempt -le 45; $attempt++) {
        $output = @(& docker compose exec -T control-plane /usr/local/bin/shieldwardd probe 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-Host ($output -join "`n")
            return
        }
        Start-Sleep -Seconds 1
    }

    throw 'Control plane did not recover within 45 seconds.'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker with Compose v2 is required for production acceptance tests.'
}
if (-not (Get-Command $curlCommand -ErrorAction SilentlyContinue)) {
    throw "$curlCommand is required for production acceptance tests."
}
if (-not (Test-Path -LiteralPath $certificateAuthorityPath -PathType Leaf)) {
    throw 'Container TLS material is missing. Run scripts/new-container-tls.ps1 first.'
}

New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

Push-Location $repoRoot
try {
    [void](Invoke-Compose -ComposeArguments @('config', '--quiet'))
    Wait-ControlPlane

    $health = Invoke-EdgeRequest -Path '/healthz'
    Assert-Status -Response $health -Expected 200 -Description 'Edge health'
    Assert-JsonValue -Response $health -Property 'status' -Expected 'ok' -Description 'Edge health'
    Assert-SecurityHeaders -Response $health -Description 'Edge health'

    Test-EdgeFailClosed -Phase 'Steady-state'
    Test-ControlPlaneIdentityGate

    if ($IncludeFailureDrills) {
        $controlPlaneStopped = $false
        try {
            [void](Invoke-Compose -ComposeArguments @('stop', 'control-plane'))
            $controlPlaneStopped = $true
            Start-Sleep -Seconds 3
            Test-EdgeFailClosed -Phase 'Control-plane outage'
            Write-Host 'Edge retained its last verified policy while the control plane was unavailable.'
        }
        finally {
            if ($controlPlaneStopped) {
                [void](Invoke-Compose -ComposeArguments @('start', 'control-plane'))
                Wait-ControlPlane
            }
        }

        Test-EdgeFailClosed -Phase 'Recovery'
    }

    Write-Host 'Production acceptance tests passed.'
}
finally {
    Pop-Location

    $resolvedTemporaryDirectory = [System.IO.Path]::GetFullPath($temporaryDirectory)
    if ($resolvedTemporaryDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
