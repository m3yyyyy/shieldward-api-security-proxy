[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\.shieldward\containers'),
    [ValidateRange(1, 90)]
    [int]$ValidDays = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$expectedFiles = @(
    'ca.pem'
    'control-plane-cert.pem'
    'control-plane-key.pem'
    'edge-cert.pem'
    'edge-key.pem'
    'edge-client-cert.pem'
    'edge-client-key.pem'
)

if (-not $Force) {
    $existingFiles = @(
        $expectedFiles | Where-Object {
            Test-Path -LiteralPath (Join-Path $outputPath $_)
        }
    )
    if ($existingFiles.Count -gt 0) {
        throw "Refusing to overwrite existing TLS material: $($existingFiles -join ', '). Use -Force to rotate it."
    }
}

New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter = $notBefore.AddDays($ValidDays)
$caNotAfter = $notAfter.AddDays(1)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-PemFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Contents,
        [Parameter(Mandatory)]
        [bool]$Private
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Contents.TrimEnd() + "`n",
        $utf8NoBom
    )

    if (-not $IsWindows) {
        $mode = if ($Private) {
            [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite
        }
        else {
            [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::OtherRead
        }
        [System.IO.File]::SetUnixFileMode($Path, $mode)
    }
}

function New-RsaKey {
    $key = [System.Security.Cryptography.RSA]::Create()
    $key.KeySize = 3072
    return $key
}

function New-LeafMaterial {
    param(
        [Parameter(Mandatory)]
        [string]$CommonName,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$DnsNames,
        [Parameter(Mandatory)]
        [string[]]$EnhancedKeyUsageOids,
        [string[]]$UriNames = @(),
        [switch]$IncludeLoopback,
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [Parameter(Mandatory)]
        [string]$PrivateKeyPath,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Issuer
    )

    $key = New-RsaKey
    try {
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$CommonName",
            $key,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
                $false,
                $false,
                0,
                $true
            )
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,
                $true
            )
        )

        $enhancedKeyUsages = [System.Security.Cryptography.OidCollection]::new()
        foreach ($oid in $EnhancedKeyUsageOids) {
            [void]$enhancedKeyUsages.Add(
                [System.Security.Cryptography.Oid]::new($oid)
            )
        }
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
                $enhancedKeyUsages,
                $true
            )
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
                $request.PublicKey,
                $false
            )
        )

        $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        foreach ($dnsName in $DnsNames) {
            $san.AddDnsName($dnsName)
        }
        foreach ($uriName in $UriNames) {
            $san.AddUri([Uri]::new($uriName))
        }
        if ($IncludeLoopback) {
            $san.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
            $san.AddIpAddress([System.Net.IPAddress]::Parse('::1'))
        }
        $request.CertificateExtensions.Add($san.Build($true))

        $serialNumber = [byte[]]::new(16)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($serialNumber)
        $serialNumber[0] = $serialNumber[0] -band 0x7f
        $serialNumber[15] = $serialNumber[15] -bor 1

        $certificate = $request.Create(
            $Issuer,
            $notBefore,
            $notAfter,
            $serialNumber
        )
        try {
            Write-PemFile -Path $CertificatePath -Contents $certificate.ExportCertificatePem() -Private $false
            Write-PemFile -Path $PrivateKeyPath -Contents $key.ExportPkcs8PrivateKeyPem() -Private $true
        }
        finally {
            $certificate.Dispose()
        }
    }
    finally {
        $key.Dispose()
    }
}

$caKey = New-RsaKey
try {
    $caRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=ShieldWard local development CA',
        $caKey,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $caRequest.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $true,
            $false,
            0,
            $true
        )
    )
    $caRequest.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign,
            $true
        )
    )
    $caRequest.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new(
            $caRequest.PublicKey,
            $false
        )
    )

    $caCertificate = $caRequest.CreateSelfSigned($notBefore, $caNotAfter)
    try {
        Write-PemFile `
            -Path (Join-Path $outputPath 'ca.pem') `
            -Contents $caCertificate.ExportCertificatePem() `
            -Private $false

        New-LeafMaterial `
            -CommonName 'shieldward-control-plane' `
            -DnsNames @(
                'control-plane',
                'shieldward-control-plane',
                'shieldward-control-plane.shieldward',
                'shieldward-control-plane.shieldward.svc',
                'shieldward-control-plane.shieldward.svc.cluster.local',
                'localhost'
            ) `
            -EnhancedKeyUsageOids @('1.3.6.1.5.5.7.3.1') `
            -IncludeLoopback `
            -CertificatePath (Join-Path $outputPath 'control-plane-cert.pem') `
            -PrivateKeyPath (Join-Path $outputPath 'control-plane-key.pem') `
            -Issuer $caCertificate

        New-LeafMaterial `
            -CommonName 'shieldward-edge' `
            -DnsNames @(
                'edge',
                'shieldward-edge',
                'shieldward-edge.shieldward',
                'shieldward-edge.shieldward.svc',
                'shieldward-edge.shieldward.svc.cluster.local',
                'localhost'
            ) `
            -EnhancedKeyUsageOids @('1.3.6.1.5.5.7.3.1') `
            -IncludeLoopback `
            -CertificatePath (Join-Path $outputPath 'edge-cert.pem') `
            -PrivateKeyPath (Join-Path $outputPath 'edge-key.pem') `
            -Issuer $caCertificate

        New-LeafMaterial `
            -CommonName 'shieldward-edge-client' `
            -DnsNames @() `
            -EnhancedKeyUsageOids @('1.3.6.1.5.5.7.3.2') `
            -UriNames @('spiffe://shieldward.local/edge') `
            -CertificatePath (Join-Path $outputPath 'edge-client-cert.pem') `
            -PrivateKeyPath (Join-Path $outputPath 'edge-client-key.pem') `
            -Issuer $caCertificate
    }
    finally {
        $caCertificate.Dispose()
    }
}
finally {
    $caKey.Dispose()
}

Get-ChildItem -LiteralPath $outputPath -File |
    Sort-Object Name |
    Select-Object Name, Length

Write-Host "Generated local-only container TLS material in $outputPath"
