[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaselineEvidencePath,

    [string]$InitialPlanPath = '',
    [string]$StagingEvidencePath = '',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedProductionContext,

    [switch]$CheckCluster
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$digestPattern = '^sha256:[0-9a-f]{64}$'
$controlPlaneRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/control-plane'
$edgeRepository = 'ghcr.io/m3yyyyy/shieldward-api-security-proxy/edge'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

function Resolve-LocalStatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
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

function Get-OptionalArrayCount {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$PropertyName
    )

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return 0
    }
    return @($property.Value).Count
}

function Invoke-LiveEdgeChecks {
    param(
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedPolicyVersion,
        [Parameter(Mandatory)][string]$ServerName
    )

    $probeScript = @"
import { readFileSync } from 'node:fs';
import { request } from 'node:https';
const ca = readFileSync('/run/secrets/shieldward/control-plane-ca.pem');
const metadata = JSON.parse(readFileSync('/app/package.json', 'utf8'));
if (metadata.version !== '$ExpectedVersion') throw new Error('unexpected Edge version');
const send = (path) => new Promise((resolve, reject) => {
  const requestHandle = request({
    hostname: '127.0.0.1', port: 8787, path, method: 'GET', ca,
    servername: '$ServerName', minVersion: 'TLSv1.2', rejectUnauthorized: true,
    agent: false,
  }, (response) => {
    const chunks = [];
    response.on('data', (chunk) => chunks.push(chunk));
    response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
  });
  requestHandle.on('error', reject);
  requestHandle.end();
});
const verify = async (path, status, property, value) => {
  const response = await send(path);
  if (response.status !== status) throw new Error(path + ' returned HTTP ' + response.status);
  const body = JSON.parse(response.body);
  if (body[property] !== value) throw new Error(path + ' returned an unexpected body');
  return body;
};
await verify('/healthz', 200, 'status', 'ok');
const ready = await verify('/readyz', 200, 'status', 'ready');
if (ready.policyVersion !== '$ExpectedPolicyVersion') throw new Error('production policy digest changed');
await verify('/unknown', 403, 'error', 'default_deny');
await verify('/v1/orders/42', 401, 'error', 'jwt_invalid');
"@
    [void](Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'exec', 'deployment/shieldward-edge',
        '-c', 'edge', '--', 'node', '--input-type=module', '--eval', $probeScript
    ))
}

$resolvedBaselinePath = Resolve-LocalStatePath -Path $BaselineEvidencePath -Description 'BaselineEvidencePath'
if (-not (Test-Path -LiteralPath $resolvedBaselinePath -PathType Leaf)) {
    throw "Production baseline evidence is missing: $resolvedBaselinePath"
}
$baseline = Get-Content -Raw -LiteralPath $resolvedBaselinePath | ConvertFrom-Json
if (
    [int]$baseline.schemaVersion -ne 1 -or
    [string]$baseline.environment -ne 'production' -or
    [string]$baseline.evidenceType -ne 'initial-baseline' -or
    [string]$baseline.state -ne 'candidate-ready-traffic-disabled'
) {
    throw 'The supplied production baseline evidence is unsupported.'
}
if ([string]$baseline.kubernetesContext -ne $ExpectedProductionContext) {
    throw "The baseline targets '$($baseline.kubernetesContext)'; expected '$ExpectedProductionContext'."
}
if ([string]$baseline.namespace -ne 'shieldward') {
    throw "The baseline uses unsupported namespace '$($baseline.namespace)'."
}
if (
    [string]$baseline.traffic.state -ne 'disabled' -or
    [bool]$baseline.traffic.externallyEnforced -ne $true -or
    [string]::IsNullOrWhiteSpace([string]$baseline.traffic.controller) -or
    [string]::IsNullOrWhiteSpace([string]$baseline.traffic.isolationEvidenceReference)
) {
    throw 'The baseline does not contain externally enforced traffic-isolation evidence.'
}
if (
    [string]::IsNullOrWhiteSpace([string]$baseline.acceptance.externalEvidenceReference) -or
    [string]::IsNullOrWhiteSpace([string]$baseline.acceptance.removalProcedureReference) -or
    [string]::IsNullOrWhiteSpace([string]$baseline.acceptance.removalDrillEvidenceReference) -or
    [string]$baseline.acceptance.edgeServerName -notmatch '^[A-Za-z0-9.-]+$'
) {
    throw 'The baseline is missing external acceptance or removal-drill evidence.'
}

$resolvedInitialPlanPath = if ([string]::IsNullOrWhiteSpace($InitialPlanPath)) {
    Resolve-LocalStatePath -Path ([string]$baseline.initialPlan.relativePath) -Description 'Recorded initial plan path'
}
else {
    Resolve-LocalStatePath -Path $InitialPlanPath -Description 'InitialPlanPath'
}
if (-not (Test-Path -LiteralPath $resolvedInitialPlanPath -PathType Leaf)) {
    throw "Recorded initial production plan is missing: $resolvedInitialPlanPath"
}
$initialPlanRelativePath = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedInitialPlanPath).Replace('\', '/')
if ($initialPlanRelativePath -ne [string]$baseline.initialPlan.relativePath) {
    throw 'The supplied initial plan path does not match the baseline evidence.'
}
$initialPlanHash = (Get-FileHash -LiteralPath $resolvedInitialPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($initialPlanHash -ne [string]$baseline.initialPlan.sha256) {
    throw 'The initial production plan hash does not match the baseline evidence.'
}

$initialValidationArguments = @{
    PlanPath = $resolvedInitialPlanPath
    ExpectedProductionContext = $ExpectedProductionContext
    RequiredState = 'Approved'
}
if (-not [string]::IsNullOrWhiteSpace($StagingEvidencePath)) {
    $initialValidationArguments.StagingEvidencePath = $StagingEvidencePath
}
& (Join-Path $PSScriptRoot 'test-initial-production-plan.ps1') @initialValidationArguments | Out-Null
$initialPlan = Get-Content -Raw -LiteralPath $resolvedInitialPlanPath | ConvertFrom-Json

if (
    [string]$baseline.initialPlan.changeId -ne [string]$initialPlan.changeId -or
    [string]$baseline.initialPlan.integrityDigest -ne [string]$initialPlan.integrityDigest -or
    [string]$baseline.releaseVersion -ne [string]$initialPlan.candidate.version -or
    [string]$baseline.sourceTag -ne [string]$initialPlan.candidate.sourceTag -or
    [string]$baseline.images.controlPlane -ne [string]$initialPlan.candidate.controlPlaneImage -or
    [string]$baseline.images.edge -ne [string]$initialPlan.candidate.edgeImage -or
    [string]$baseline.traffic.controller -ne [string]$initialPlan.traffic.controller -or
    [string]$baseline.acceptance.removalProcedureReference -ne [string]$initialPlan.rollback.procedureReference
) {
    throw 'The production baseline no longer matches the approved initial installation plan.'
}

foreach ($imageContract in @(
    [pscustomobject]@{ Image = [string]$baseline.images.controlPlane; Repository = $controlPlaneRepository }
    [pscustomobject]@{ Image = [string]$baseline.images.edge; Repository = $edgeRepository }
)) {
    if ($imageContract.Image -notmatch "^$([regex]::Escape($imageContract.Repository))@sha256:[0-9a-f]{64}$") {
        throw "Baseline image is not an approved digest-pinned reference: $($imageContract.Image)"
    }
}

$edgeChecks = $baseline.acceptance.edge
if (
    [string]$baseline.acceptance.controlPlaneRuntimeVersion -ne [string]$baseline.releaseVersion -or
    [string]$edgeChecks.healthStatus -ne 'ok' -or
    [string]$edgeChecks.readyStatus -ne 'ready' -or
    [string]$edgeChecks.runtimeVersion -ne [string]$baseline.releaseVersion -or
    [string]$edgeChecks.policyVersion -notmatch $digestPattern -or
    [string]$edgeChecks.policyVersion -ne [string]$initialPlan.stagingEvidence.policyVersion -or
    [int]$edgeChecks.defaultDenyStatus -ne 403 -or
    [int]$edgeChecks.protectedRouteStatus -ne 401
) {
    throw 'The production baseline acceptance checks did not pass.'
}

$deploymentContracts = @(
    [pscustomobject]@{ Name = 'shieldward-control-plane'; Image = [string]$baseline.images.controlPlane }
    [pscustomobject]@{ Name = 'shieldward-edge'; Image = [string]$baseline.images.edge }
)
$orderedDeployments = @()
foreach ($contract in $deploymentContracts) {
    $deployment = @($baseline.deployments) |
        Where-Object { [string]$_.name -eq $contract.Name } |
        Select-Object -First 1
    if (
        $null -eq $deployment -or
        [string]$deployment.image -ne $contract.Image -or
        [int]$deployment.desiredReplicas -lt 1 -or
        [int]$deployment.availableReplicas -lt [int]$deployment.desiredReplicas -or
        [long]$deployment.observedGeneration -lt 1
    ) {
        throw "The production baseline deployment $($contract.Name) is invalid."
    }
    $orderedDeployments += $deployment
}

$orderedServices = @()
foreach ($serviceName in @('shieldward-control-plane', 'shieldward-edge')) {
    $service = @($baseline.services) |
        Where-Object { [string]$_.name -eq $serviceName } |
        Select-Object -First 1
    if (
        $null -eq $service -or
        [string]$service.type -ne 'ClusterIP' -or
        [string]::IsNullOrWhiteSpace([string]$service.clusterIP) -or
        [int]$service.externalIPCount -ne 0 -or
        [int]$service.loadBalancerIngressCount -ne 0
    ) {
        throw "The production baseline service $serviceName is externally exposed or invalid."
    }
    $orderedServices += $service
}

$deploymentSummary = @($orderedDeployments | ForEach-Object {
    "$($_.name)|$($_.image)|$($_.desiredReplicas)|$($_.availableReplicas)|$($_.observedGeneration)"
}) -join ';'
$serviceSummary = @($orderedServices | ForEach-Object {
    "$($_.name)|$($_.type)|$($_.clusterIP)|$($_.externalIPCount)|$($_.loadBalancerIngressCount)"
}) -join ';'
try {
    $collectedAt = [DateTimeOffset]$baseline.collectedAtUtc
}
catch {
    throw 'The production baseline collection timestamp is invalid.'
}
$integrity = [ordered]@{
    initialPlanSha256 = [string]$baseline.initialPlan.sha256
    collectedAtUtc = $collectedAt.ToUniversalTime().ToString('o')
    productionContext = [string]$baseline.kubernetesContext
    namespace = [string]$baseline.namespace
    releaseVersion = [string]$baseline.releaseVersion
    controlPlaneImage = [string]$baseline.images.controlPlane
    edgeImage = [string]$baseline.images.edge
    trafficState = [string]$baseline.traffic.state
    trafficController = [string]$baseline.traffic.controller
    trafficIsolationEvidenceReference = [string]$baseline.traffic.isolationEvidenceReference
    acceptanceEvidenceReference = [string]$baseline.acceptance.externalEvidenceReference
    removalProcedureReference = [string]$baseline.acceptance.removalProcedureReference
    removalDrillEvidenceReference = [string]$baseline.acceptance.removalDrillEvidenceReference
    edgeServerName = [string]$baseline.acceptance.edgeServerName
    controlPlaneRuntimeVersion = [string]$baseline.acceptance.controlPlaneRuntimeVersion
    policyVersion = [string]$edgeChecks.policyVersion
    deploymentSummary = $deploymentSummary
    serviceSummary = $serviceSummary
}
if ((Get-Sha256Text -Text ($integrity | ConvertTo-Json -Depth 4 -Compress)) -ne [string]$baseline.integrityDigest) {
    throw 'The production baseline evidence integrity digest is invalid.'
}

if ($collectedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    throw 'The production baseline collection timestamp is in the future.'
}

if ($CheckCluster) {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl is required to recheck the production baseline.'
    }
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
    foreach ($contract in $deploymentContracts) {
        $raw = (Invoke-Kubectl -Arguments @(
            '-n', 'shieldward', 'get', 'deployment', $contract.Name, '-o', 'json'
        ) | Out-String)
        $deployment = $raw | ConvertFrom-Json
        $expectedContainerName = if ($contract.Name -eq 'shieldward-control-plane') { 'control-plane' } else { 'edge' }
        $container = @($deployment.spec.template.spec.containers) |
            Where-Object {
                [string]$_.name -eq $expectedContainerName -and
                [string]$_.image -eq $contract.Image
            } |
            Select-Object -First 1
        if (
            $null -eq $container -or
            [int]$deployment.status.availableReplicas -lt [int]$deployment.spec.replicas -or
            [long]$deployment.status.observedGeneration -lt [long]$deployment.metadata.generation
        ) {
            throw "Live production deployment $($contract.Name) no longer matches the baseline."
        }
    }
    foreach ($serviceName in @('shieldward-control-plane', 'shieldward-edge')) {
        $raw = (Invoke-Kubectl -Arguments @(
            '-n', 'shieldward', 'get', 'service', $serviceName, '-o', 'json'
        ) | Out-String)
        $service = $raw | ConvertFrom-Json
        $loadBalancerProperty = $service.status.PSObject.Properties['loadBalancer']
        $loadBalancerIngressCount = if ($null -eq $loadBalancerProperty) {
            0
        }
        else {
            Get-OptionalArrayCount -Object $loadBalancerProperty.Value -PropertyName 'ingress'
        }
        if (
            [string]$service.spec.type -ne 'ClusterIP' -or
            (Get-OptionalArrayCount -Object $service.spec -PropertyName 'externalIPs') -ne 0 -or
            $loadBalancerIngressCount -ne 0
        ) {
            throw "Live production service $serviceName is externally exposed."
        }
    }
    $ingresses = (Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'get', 'ingress',
        '-l', 'app.kubernetes.io/name=shieldward', '-o', 'name'
    ) | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($ingresses)) {
        throw "Live ShieldWard Ingress resources exist before traffic approval:`n$ingresses"
    }
    $controlPlaneVersion = (Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'exec', 'deployment/shieldward-control-plane',
        '-c', 'control-plane', '--', '/usr/local/bin/shieldwardd', 'version'
    ) | Out-String).Trim()
    if ($controlPlaneVersion -ne [string]$baseline.releaseVersion) {
        throw "Live control-plane version '$controlPlaneVersion' no longer matches the baseline."
    }
    [void](Invoke-Kubectl -Arguments @(
        '-n', 'shieldward', 'exec', 'deployment/shieldward-control-plane',
        '-c', 'control-plane', '--', '/usr/local/bin/shieldwardd', 'probe'
    ))
    Invoke-LiveEdgeChecks `
        -ExpectedVersion ([string]$baseline.releaseVersion) `
        -ExpectedPolicyVersion ([string]$baseline.acceptance.edge.policyVersion) `
        -ServerName ([string]$baseline.acceptance.edgeServerName)
    Write-Host 'Live production baseline recheck passed. No cluster changes were made.'
}

Write-Host "Production baseline evidence validation passed for v$($baseline.releaseVersion)."
Write-Host 'Traffic isolation remains externally enforced; this validator does not change or authorize routing.'
