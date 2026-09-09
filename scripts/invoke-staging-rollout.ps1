[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedContext,

    [string]$BundleDirectory = '.shieldward/staging',
    [string]$EvidenceDirectory = '.shieldward/evidence',
    [string]$EdgeServerName = 'shieldward-edge.shieldward.svc.cluster.local',

    [ValidatePattern('^[1-9][0-9]*[smh]$')]
    [string]$Timeout = '5m',

    [switch]$IncludeControlPlaneOutageDrill
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($EdgeServerName -notmatch '^[A-Za-z0-9.-]+$') {
    throw "EdgeServerName '$EdgeServerName' is invalid."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

function Resolve-LocalStateChild {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description must not be empty."
    }
    $resolved = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
    }
    if (-not $resolved.StartsWith($localStatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be beneath the ignored .shieldward directory."
    }
    return $resolved
}

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& kubectl --context $ExpectedContext @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return $output
}

function Get-DeploymentSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Namespace,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Container,
        [Parameter(Mandatory)]
        [string]$ExpectedImage
    )

    $raw = (Invoke-Kubectl -Arguments @(
        '-n', $Namespace, 'get', 'deployment', $Name, '-o', 'json'
    ) | Out-String)
    $deployment = $raw | ConvertFrom-Json
    $containerSpec = @($deployment.spec.template.spec.containers) |
        Where-Object { $_.name -eq $Container } |
        Select-Object -First 1
    if ($null -eq $containerSpec) {
        throw "Deployment $Name has no container named $Container."
    }
    if ([string]$containerSpec.image -ne $ExpectedImage) {
        throw "Deployment $Name uses '$($containerSpec.image)'; expected '$ExpectedImage'."
    }

    $desiredReplicas = [int]$deployment.spec.replicas
    $availableReplicas = if ($null -eq $deployment.status.availableReplicas) {
        0
    }
    else {
        [int]$deployment.status.availableReplicas
    }
    if ($availableReplicas -lt $desiredReplicas) {
        throw "Deployment $Name has $availableReplicas available replicas; expected $desiredReplicas."
    }
    if ([long]$deployment.status.observedGeneration -lt [long]$deployment.metadata.generation) {
        throw "Deployment $Name has not observed its latest generation."
    }

    return [pscustomobject]@{
        name = $Name
        image = [string]$containerSpec.image
        desiredReplicas = $desiredReplicas
        availableReplicas = $availableReplicas
        observedGeneration = [long]$deployment.status.observedGeneration
        conditions = @($deployment.status.conditions | ForEach-Object {
            [pscustomobject]@{
                type = [string]$_.type
                status = [string]$_.status
                reason = [string]$_.reason
                lastTransitionTime = [string]$_.lastTransitionTime
            }
        })
    }
}

function Invoke-EdgeChecks {
    param(
        [Parameter(Mandatory)]
        [string]$Namespace,
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$ExpectedVersion
    )

    $probeScript = @"
import { readFileSync } from 'node:fs';
import { request } from 'node:https';

const ca = readFileSync('/run/secrets/shieldward/control-plane-ca.pem');
const packageMetadata = JSON.parse(readFileSync('/app/package.json', 'utf8'));
if (packageMetadata.version !== '$ExpectedVersion') {
  throw new Error('Edge runtime version is ' + packageMetadata.version + '; expected $ExpectedVersion');
}
const send = (path) => new Promise((resolve, reject) => {
  const outgoing = request({
    hostname: '127.0.0.1',
    port: 8787,
    path,
    method: 'GET',
    ca,
    servername: '$ServerName',
    minVersion: 'TLSv1.2',
    rejectUnauthorized: true,
    agent: false,
  }, (incoming) => {
    const chunks = [];
    incoming.on('data', (chunk) => chunks.push(chunk));
    incoming.on('end', () => resolve({
      status: incoming.statusCode,
      headers: incoming.headers,
      body: Buffer.concat(chunks).toString('utf8'),
    }));
  });
  outgoing.on('error', reject);
  outgoing.end();
});

const assertResponse = (response, expectedStatus, expectedProperty, expectedValue, description) => {
  if (response.status !== expectedStatus) {
    throw new Error(description + ' returned HTTP ' + response.status + ': ' + response.body);
  }
  const body = JSON.parse(response.body);
  if (body[expectedProperty] !== expectedValue) {
    throw new Error(description + ' returned an unexpected body: ' + response.body);
  }
  for (const [name, value] of [
    ['x-content-type-options', 'nosniff'],
    ['referrer-policy', 'no-referrer'],
    ['strict-transport-security', 'max-age=31536000'],
    ['cache-control', 'no-store'],
  ]) {
    if (response.headers[name] !== value) {
      throw new Error(description + ' is missing ' + name + ': ' + value);
    }
  }
  return body;
};

const health = assertResponse(await send('/healthz'), 200, 'status', 'ok', 'health');
const ready = assertResponse(await send('/readyz'), 200, 'status', 'ready', 'readiness');
if (!/^sha256:[0-9a-f]{64}$/.test(ready.policyVersion ?? '')) {
  throw new Error('readiness did not report a verified policy version');
}
assertResponse(await send('/unknown'), 403, 'error', 'default_deny', 'default deny');
assertResponse(await send('/v1/orders/42'), 401, 'error', 'jwt_invalid', 'protected route');
console.log(JSON.stringify({
  healthStatus: health.status,
  readyStatus: ready.status,
  runtimeVersion: packageMetadata.version,
  policyVersion: ready.policyVersion,
  defaultDenyStatus: 403,
  protectedRouteStatus: 401,
}));
"@

    $output = @(Invoke-Kubectl -Arguments @(
        '-n', $Namespace,
        'exec', 'deployment/shieldward-edge',
        '-c', 'edge', '--',
        'node', '--input-type=module', '--eval', $probeScript
    ))
    $jsonLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
        Select-Object -Last 1
    try {
        return $jsonLine | ConvertFrom-Json
    }
    catch {
        throw "Edge acceptance checks returned invalid output:`n$($output -join "`n")"
    }
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl is required for the staging rollout.'
}

$resolvedBundleDirectory = Resolve-LocalStateChild -Path $BundleDirectory -Description 'BundleDirectory'
$resolvedEvidenceDirectory = Resolve-LocalStateChild -Path $EvidenceDirectory -Description 'EvidenceDirectory'
$metadataPath = Join-Path $resolvedBundleDirectory 'rollout.json'
$kustomizationPath = Join-Path $resolvedBundleDirectory 'kustomization.yaml'
foreach ($requiredPath in @($metadataPath, $kustomizationPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Staging bundle file is missing: $requiredPath"
    }
}

$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
if ([int]$metadata.schemaVersion -ne 1 -or [string]$metadata.environment -ne 'staging') {
    throw 'The rollout metadata is not a supported staging bundle.'
}
$releaseVersion = [string]$metadata.releaseVersion
if ($releaseVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    throw "The staging bundle has invalid release version '$releaseVersion'."
}
if ([string]$metadata.sourceTag -ne "v$releaseVersion") {
    throw 'The staging bundle source tag does not match its release version.'
}
$namespace = [string]$metadata.namespace
if ($namespace -ne 'shieldward') {
    throw "The staging bundle uses unsupported namespace '$namespace'."
}
$controlPlaneImage = [string]$metadata.images.controlPlane.reference
$edgeImage = [string]$metadata.images.edge.reference
foreach ($image in @($controlPlaneImage, $edgeImage)) {
    if ($image -notmatch '^ghcr\.io/m3yyyyy/shieldward-api-security-proxy/(?:control-plane|edge)@sha256:[0-9a-f]{64}$') {
        throw "Staging image reference is not digest-pinned: $image"
    }
}

$kustomization = [System.IO.File]::ReadAllText($kustomizationPath)
foreach ($digest in @(
    [string]$metadata.images.controlPlane.digest,
    [string]$metadata.images.edge.digest
)) {
    if (-not $kustomization.Contains("digest: $digest", [StringComparison]::Ordinal)) {
        throw "Staging kustomization does not contain expected digest '$digest'."
    }
}
if ($kustomization -match '(?i)REPLACE|:latest(?:\s|$)') {
    throw 'Staging kustomization contains a placeholder or mutable latest tag.'
}

$currentContextOutput = @(& kubectl config current-context 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "kubectl config current-context failed:`n$($currentContextOutput -join "`n")"
}
$currentContext = ($currentContextOutput | Out-String).Trim()
if (-not [string]::Equals($currentContext, $ExpectedContext, [StringComparison]::Ordinal)) {
    throw "Current Kubernetes context is '$currentContext'; expected '$ExpectedContext'."
}

[void](Invoke-Kubectl -Arguments @('get', 'namespace', $namespace, '-o', 'name'))
foreach ($secretName in @(
    'shieldward-control-plane-credentials',
    'shieldward-edge-credentials'
)) {
    [void](Invoke-Kubectl -Arguments @(
        '-n', $namespace, 'get', 'secret', $secretName, '-o', 'name'
    ))
}

$rendered = (Invoke-Kubectl -Arguments @('kustomize', $resolvedBundleDirectory) | Out-String)
foreach ($image in @($controlPlaneImage, $edgeImage)) {
    if (-not $rendered.Contains("image: $image", [StringComparison]::Ordinal)) {
        throw "Rendered staging manifest does not contain '$image'."
    }
}

$outageStarted = $false
$originalControlPlaneReplicas = 0
$outageChecks = $null
try {
    [void](Invoke-Kubectl -Arguments @('apply', '-k', $resolvedBundleDirectory))
    [void](Invoke-Kubectl -Arguments @(
        '-n', $namespace, 'rollout', 'status',
        'deployment/shieldward-control-plane', "--timeout=$Timeout"
    ))
    [void](Invoke-Kubectl -Arguments @(
        '-n', $namespace, 'rollout', 'status',
        'deployment/shieldward-edge', "--timeout=$Timeout"
    ))

    $controlPlane = Get-DeploymentSnapshot -Namespace $namespace -Name 'shieldward-control-plane' -Container 'control-plane' -ExpectedImage $controlPlaneImage
    $edge = Get-DeploymentSnapshot -Namespace $namespace -Name 'shieldward-edge' -Container 'edge' -ExpectedImage $edgeImage

    $controlPlaneVersion = (Invoke-Kubectl -Arguments @(
        '-n', $namespace,
        'exec', 'deployment/shieldward-control-plane',
        '-c', 'control-plane', '--',
        '/usr/local/bin/shieldwardd', 'version'
    ) | Out-String).Trim()
    if ($controlPlaneVersion -ne $releaseVersion) {
        throw "Control-plane runtime version is '$controlPlaneVersion'; expected '$releaseVersion'."
    }

    [void](Invoke-Kubectl -Arguments @(
        '-n', $namespace,
        'exec', 'deployment/shieldward-control-plane',
        '-c', 'control-plane', '--',
        '/usr/local/bin/shieldwardd', 'probe'
    ))
    $steadyStateChecks = Invoke-EdgeChecks -Namespace $namespace -ServerName $EdgeServerName -ExpectedVersion $releaseVersion

    if ($IncludeControlPlaneOutageDrill) {
        $originalControlPlaneReplicas = [int]$controlPlane.desiredReplicas
        if ($originalControlPlaneReplicas -lt 1) {
            throw 'Control-plane outage drill requires at least one running replica.'
        }

        [void](Invoke-Kubectl -Arguments @(
            '-n', $namespace, 'scale',
            'deployment/shieldward-control-plane', '--replicas=0'
        ))
        $outageStarted = $true
        [void](Invoke-Kubectl -Arguments @(
            '-n', $namespace, 'rollout', 'status',
            'deployment/shieldward-control-plane', "--timeout=$Timeout"
        ))
        Start-Sleep -Seconds 5
        $outageChecks = Invoke-EdgeChecks -Namespace $namespace -ServerName $EdgeServerName -ExpectedVersion $releaseVersion
    }
}
finally {
    if ($outageStarted) {
        [void](Invoke-Kubectl -Arguments @(
            '-n', $namespace, 'scale',
            'deployment/shieldward-control-plane',
            "--replicas=$originalControlPlaneReplicas"
        ))
        [void](Invoke-Kubectl -Arguments @(
            '-n', $namespace, 'rollout', 'status',
            'deployment/shieldward-control-plane', "--timeout=$Timeout"
        ))
    }
}

if ($IncludeControlPlaneOutageDrill) {
    [void](Invoke-Kubectl -Arguments @(
        '-n', $namespace,
        'exec', 'deployment/shieldward-control-plane',
        '-c', 'control-plane', '--',
        '/usr/local/bin/shieldwardd', 'probe'
    ))
    $recoveryChecks = Invoke-EdgeChecks -Namespace $namespace -ServerName $EdgeServerName -ExpectedVersion $releaseVersion
}
else {
    $recoveryChecks = $null
}

$finalControlPlane = Get-DeploymentSnapshot -Namespace $namespace -Name 'shieldward-control-plane' -Container 'control-plane' -ExpectedImage $controlPlaneImage
$finalEdge = Get-DeploymentSnapshot -Namespace $namespace -Name 'shieldward-edge' -Container 'edge' -ExpectedImage $edgeImage

New-Item -ItemType Directory -Path $resolvedEvidenceDirectory -Force | Out-Null
$timestamp = [DateTimeOffset]::UtcNow
$safeTimestamp = $timestamp.ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedEvidenceDirectory (
    "staging-$($metadata.releaseVersion)-$safeTimestamp.json"
)
$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'staging'
    collectedAtUtc = $timestamp.ToString('o')
    kubernetesContext = $currentContext
    namespace = $namespace
    releaseVersion = $releaseVersion
    sourceTag = [string]$metadata.sourceTag
    images = [ordered]@{
        controlPlane = $controlPlaneImage
        edge = $edgeImage
    }
    checks = [ordered]@{
        controlPlaneRuntimeVersion = $controlPlaneVersion
        steadyState = $steadyStateChecks
        controlPlaneOutage = $outageChecks
        recovery = $recoveryChecks
    }
    deployments = @($finalControlPlane, $finalEdge)
}
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n")
)

Write-Host "Staging rollout passed for v$($metadata.releaseVersion)."
Write-Host "Sanitized evidence: $evidencePath"
