[CmdletBinding()]
param(
    [string]$InitialPlanPath = '.shieldward/production-initial/installation.json',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TrafficIsolationEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AcceptanceEvidenceReference,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RemovalDrillEvidenceReference,

    [string]$EdgeServerName = 'shieldward-edge.shieldward.svc.cluster.local',
    [string]$OutputDirectory = '.shieldward/production-baseline',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

function Resolve-LocalStatePath {
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

function Assert-EvidenceReference {
    param(
        [Parameter(Mandatory)]
        [string]$Value,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 256 -or
        $Value -match '[\x00-\x1f]' -or
        $Value -match '(?i)REPLACE'
    ) {
        throw "$Description must be a non-placeholder value of at most 256 characters without control characters."
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([Convert]::ToHexString($sha256.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(& kubectl --context $ExpectedProductionContext @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return $output
}

function Get-DeploymentSnapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$ExpectedImage
    )

    $raw = (Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'get', 'deployment', $Name, '-o', 'json'
    ) | Out-String)
    $deployment = $raw | ConvertFrom-Json
    $containerSpec = @($deployment.spec.template.spec.containers) |
        Where-Object { [string]$_.name -eq $Container } |
        Select-Object -First 1
    if ($null -eq $containerSpec -or [string]$containerSpec.image -ne $ExpectedImage) {
        throw "Production deployment $Name does not use the approved candidate image."
    }
    $desiredReplicas = [int]$deployment.spec.replicas
    $availableReplicas = if ($null -eq $deployment.status.availableReplicas) {
        0
    }
    else {
        [int]$deployment.status.availableReplicas
    }
    if ($desiredReplicas -lt 1 -or $availableReplicas -lt $desiredReplicas) {
        throw "Production deployment $Name is not fully available."
    }
    if ([long]$deployment.status.observedGeneration -lt [long]$deployment.metadata.generation) {
        throw "Production deployment $Name has not observed its latest generation."
    }
    $available = @($deployment.status.conditions) |
        Where-Object { [string]$_.type -eq 'Available' -and [string]$_.status -eq 'True' } |
        Select-Object -First 1
    if ($null -eq $available) {
        throw "Production deployment $Name has no successful Available condition."
    }

    return [pscustomobject]@{
        name = $Name
        image = [string]$containerSpec.image
        desiredReplicas = $desiredReplicas
        availableReplicas = $availableReplicas
        observedGeneration = [long]$deployment.status.observedGeneration
    }
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory)][string]$Name)

    $raw = (Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'get', 'service', $Name, '-o', 'json'
    ) | Out-String)
    $service = $raw | ConvertFrom-Json
    $externalIPsProperty = $service.spec.PSObject.Properties['externalIPs']
    $externalIPCount = if ($null -eq $externalIPsProperty) {
        0
    }
    else {
        @($externalIPsProperty.Value).Count
    }
    $loadBalancerProperty = $service.status.PSObject.Properties['loadBalancer']
    $loadBalancerIngressCount = if ($null -eq $loadBalancerProperty) {
        0
    }
    else {
        $ingressProperty = $loadBalancerProperty.Value.PSObject.Properties['ingress']
        if ($null -eq $ingressProperty) { 0 } else { @($ingressProperty.Value).Count }
    }
    if (
        [string]$service.spec.type -ne 'ClusterIP' -or
        $externalIPCount -ne 0 -or
        $loadBalancerIngressCount -ne 0
    ) {
        throw "Production service $Name has external exposure; traffic-disabled evidence cannot be recorded."
    }
    return [pscustomobject]@{
        name = $Name
        type = [string]$service.spec.type
        clusterIP = [string]$service.spec.clusterIP
        externalIPCount = $externalIPCount
        loadBalancerIngressCount = $loadBalancerIngressCount
    }
}

function Invoke-EdgeChecks {
    param([Parameter(Mandatory)][string]$ExpectedVersion)

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
    hostname: '127.0.0.1', port: 8787, path, method: 'GET', ca,
    servername: '$EdgeServerName', minVersion: 'TLSv1.2',
    rejectUnauthorized: true, agent: false,
  }, (incoming) => {
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
const read = async (path, status, property, value) => {
  const response = await send(path);
  if (response.status !== status) throw new Error(path + ' returned HTTP ' + response.status);
  const body = JSON.parse(response.body);
  if (body[property] !== value) throw new Error(path + ' returned an unexpected body');
  return body;
};
const health = await read('/healthz', 200, 'status', 'ok');
const ready = await read('/readyz', 200, 'status', 'ready');
if (!/^sha256:[0-9a-f]{64}$/.test(ready.policyVersion ?? '')) {
  throw new Error('readiness did not report a verified policy version');
}
await read('/unknown', 403, 'error', 'default_deny');
await read('/v1/orders/42', 401, 'error', 'jwt_invalid');
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
        '-n', 'shieldward', 'exec', 'deployment/shieldward-edge',
        '-c', 'edge', '--', 'node', '--input-type=module', '--eval', $probeScript
    ))
    $jsonLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
        Select-Object -Last 1
    try {
        return $jsonLine | ConvertFrom-Json
    }
    catch {
        throw "Edge baseline checks returned invalid output:`n$($output -join "`n")"
    }
}

Assert-EvidenceReference -Value $TrafficIsolationEvidenceReference -Description 'TrafficIsolationEvidenceReference'
Assert-EvidenceReference -Value $AcceptanceEvidenceReference -Description 'AcceptanceEvidenceReference'
Assert-EvidenceReference -Value $RemovalDrillEvidenceReference -Description 'RemovalDrillEvidenceReference'
if ($EdgeServerName -notmatch '^[A-Za-z0-9.-]+$') {
    throw "EdgeServerName '$EdgeServerName' is invalid."
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl is required to collect the production baseline.'
}

$resolvedInitialPlanPath = Resolve-LocalStatePath -Path $InitialPlanPath -Description 'InitialPlanPath'
$validationArguments = @{
    PlanPath = $resolvedInitialPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $validationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') @validationArguments | Out-Null
$initialPlan = Get-Content -Raw -LiteralPath $resolvedInitialPlanPath | ConvertFrom-Json

$currentContextOutput = @(& kubectl config current-context 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "kubectl config current-context failed:`n$($currentContextOutput -join "`n")"
}
$currentContext = ($currentContextOutput | Out-String).Trim()
if (-not [string]::Equals($currentContext, $ExpectedProductionContext, [StringComparison]::Ordinal)) {
    throw "Current Kubernetes context is '$currentContext'; expected '$ExpectedProductionContext'."
}

[void](Invoke-Kubectl -Arguments @('get', 'namespace', 'shieldward', '-o', 'name'))
foreach ($secretName in @('shieldward-control-plane-credentials', 'shieldward-edge-credentials')) {
    [void](Invoke-Kubectl -Arguments @('-n', 'shieldward', 'get', 'secret', $secretName, '-o', 'name'))
}

$controlPlane = Get-DeploymentSnapshot `
    -Name 'shieldward-control-plane' `
    -Container 'control-plane' `
    -ExpectedImage ([string]$initialPlan.candidate.controlPlaneImage)
$edge = Get-DeploymentSnapshot `
    -Name 'shieldward-edge' `
    -Container 'edge' `
    -ExpectedImage ([string]$initialPlan.candidate.edgeImage)
$controlPlaneService = Get-ServiceSnapshot -Name 'shieldward-control-plane'
$edgeService = Get-ServiceSnapshot -Name 'shieldward-edge'

$ingresses = (Invoke-Kubectl -Arguments @(
    '-n', 'shieldward', 'get', 'ingress',
    '-l', 'app.kubernetes.io/name=shieldward', '-o', 'name'
) | Out-String).Trim()
if (-not [string]::IsNullOrWhiteSpace($ingresses)) {
    throw "ShieldWard Ingress resources exist while traffic should be disabled:`n$ingresses"
}

$releaseVersion = [string]$initialPlan.candidate.version
$controlPlaneVersion = (Invoke-Kubectl -Arguments @(
    '-n', 'shieldward', 'exec', 'deployment/shieldward-control-plane',
    '-c', 'control-plane', '--', '/usr/local/bin/shieldwardd', 'version'
) | Out-String).Trim()
if ($controlPlaneVersion -ne $releaseVersion) {
    throw "Control-plane runtime version is '$controlPlaneVersion'; expected '$releaseVersion'."
}
[void](Invoke-Kubectl -Arguments @(
    '-n', 'shieldward', 'exec', 'deployment/shieldward-control-plane',
    '-c', 'control-plane', '--', '/usr/local/bin/shieldwardd', 'probe'
))
$edgeChecks = Invoke-EdgeChecks -ExpectedVersion $releaseVersion
if ([string]$edgeChecks.policyVersion -ne [string]$initialPlan.stagingEvidence.policyVersion) {
    throw 'The production policy digest does not match the verified staging policy digest.'
}

$resolvedOutputDirectory = Resolve-LocalStatePath -Path $OutputDirectory -Description 'OutputDirectory'
$timestamp = [DateTimeOffset]::UtcNow
$safeTimestamp = $timestamp.ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $resolvedOutputDirectory "baseline-$releaseVersion-$safeTimestamp.json"
if ((Test-Path -LiteralPath $evidencePath) -and -not $Force) {
    throw "Production baseline evidence already exists: $evidencePath"
}

$initialPlanHash = (Get-FileHash -LiteralPath $resolvedInitialPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$initialPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedInitialPlanPath).Replace('\', '/')
$deploymentSummary = @($controlPlane, $edge | ForEach-Object {
    "$($_.name)|$($_.image)|$($_.desiredReplicas)|$($_.availableReplicas)|$($_.observedGeneration)"
}) -join ';'
$serviceSummary = @($controlPlaneService, $edgeService | ForEach-Object {
    "$($_.name)|$($_.type)|$($_.clusterIP)|$($_.externalIPCount)|$($_.loadBalancerIngressCount)"
}) -join ';'
$integrity = [ordered]@{
    initialPlanSha256 = $initialPlanHash
    collectedAtUtc = $timestamp.ToUniversalTime().ToString('o')
    productionContext = $ExpectedProductionContext
    namespace = 'shieldward'
    releaseVersion = $releaseVersion
    controlPlaneImage = [string]$initialPlan.candidate.controlPlaneImage
    edgeImage = [string]$initialPlan.candidate.edgeImage
    trafficState = 'disabled'
    trafficController = [string]$initialPlan.traffic.controller
    trafficIsolationEvidenceReference = $TrafficIsolationEvidenceReference
    acceptanceEvidenceReference = $AcceptanceEvidenceReference
    removalProcedureReference = [string]$initialPlan.rollback.procedureReference
    removalDrillEvidenceReference = $RemovalDrillEvidenceReference
    edgeServerName = $EdgeServerName
    controlPlaneRuntimeVersion = $controlPlaneVersion
    policyVersion = [string]$edgeChecks.policyVersion
    deploymentSummary = $deploymentSummary
    serviceSummary = $serviceSummary
}
$integrityDigest = Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)

$evidence = [ordered]@{
    schemaVersion = 1
    environment = 'production'
    evidenceType = 'initial-baseline'
    state = 'candidate-ready-traffic-disabled'
    collectedAtUtc = $timestamp.ToString('o')
    kubernetesContext = $ExpectedProductionContext
    namespace = 'shieldward'
    initialPlan = [ordered]@{
        relativePath = $initialPlanRelativePath
        sha256 = $initialPlanHash
        changeId = [string]$initialPlan.changeId
        integrityDigest = [string]$initialPlan.integrityDigest
    }
    releaseVersion = $releaseVersion
    sourceTag = [string]$initialPlan.candidate.sourceTag
    images = [ordered]@{
        controlPlane = [string]$initialPlan.candidate.controlPlaneImage
        edge = [string]$initialPlan.candidate.edgeImage
    }
    traffic = [ordered]@{
        state = 'disabled'
        controller = [string]$initialPlan.traffic.controller
        isolationEvidenceReference = $TrafficIsolationEvidenceReference
        externallyEnforced = $true
    }
    acceptance = [ordered]@{
        externalEvidenceReference = $AcceptanceEvidenceReference
        removalProcedureReference = [string]$initialPlan.rollback.procedureReference
        removalDrillEvidenceReference = $RemovalDrillEvidenceReference
        edgeServerName = $EdgeServerName
        controlPlaneRuntimeVersion = $controlPlaneVersion
        edge = $edgeChecks
    }
    deployments = @($controlPlane, $edge)
    services = @($controlPlaneService, $edgeService)
    integrityDigest = $integrityDigest
}

New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText(
    $evidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Traffic-disabled production baseline passed for v$releaseVersion."
Write-Host "Sanitized baseline evidence: $evidencePath"
Write-Host 'No Secret values were read and no cluster or traffic changes were made.'
