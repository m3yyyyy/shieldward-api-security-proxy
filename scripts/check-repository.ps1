[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$findings = [System.Collections.Generic.List[string]]::new()

Push-Location $repoRoot
try {
    $trackedFiles = @(& git ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw 'git ls-files failed.'
    }

    $allowedSensitivePaths = @(
        '.env.example'
        'edge/tests/fixtures/go-public.pem'
    )

    $sensitivePathRules = @(
        [pscustomobject]@{ Description = 'local ShieldWard state'; Pattern = '(^|/)\.shieldward/' }
        [pscustomobject]@{ Description = 'environment file'; Pattern = '(^|/)\.env(?:\..*)?$' }
        [pscustomobject]@{ Description = 'private key container'; Pattern = '(?i)\.(?:key|p12|pfx)$' }
        [pscustomobject]@{ Description = 'private-key PEM name'; Pattern = '(?i)(?:private|secret|dev-key|server-key|client-key).*\.pem$' }
    )

    foreach ($relativePath in $trackedFiles) {
        $normalizedPath = $relativePath.Replace('\', '/')
        if ($allowedSensitivePaths -contains $normalizedPath) {
            continue
        }

        foreach ($rule in $sensitivePathRules) {
            if ($normalizedPath -match $rule.Pattern) {
                $findings.Add("Tracked $($rule.Description): $normalizedPath")
                break
            }
        }
    }

    $contentRules = @(
        [pscustomobject]@{
            Description = 'PEM private key'
            Pattern = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
        }
        [pscustomobject]@{
            Description = 'GitHub token'
            Pattern = '(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{36,})'
        }
        [pscustomobject]@{
            Description = 'AWS access key ID'
            Pattern = '(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])'
        }
        [pscustomobject]@{
            Description = 'Slack token'
            Pattern = 'xox[baprs]-[A-Za-z0-9-]{20,}'
        }
    )

    $binaryExtensions = @(
        '.7z', '.avi', '.bmp', '.dll', '.exe', '.gif', '.gz', '.ico', '.jpeg',
        '.jpg', '.mov', '.mp3', '.mp4', '.pdf', '.png', '.so', '.tar', '.webp',
        '.woff', '.woff2', '.zip'
    )

    foreach ($relativePath in $trackedFiles) {
        $normalizedPath = $relativePath.Replace('\', '/')
        if ($normalizedPath -eq 'scripts/check-repository.ps1') {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        if ($binaryExtensions -contains $extension) {
            continue
        }

        $absolutePath = Join-Path $repoRoot $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            continue
        }

        $content = [System.IO.File]::ReadAllText($absolutePath)
        foreach ($rule in $contentRules) {
            if (
                $rule.Description -eq 'PEM private key' -and
                $normalizedPath -eq 'edge/tests/tls.test.ts'
            ) {
                # This test contains deliberately invalid placeholder PEM bodies.
                continue
            }

            $match = [regex]::Match(
                $content,
                $rule.Pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if ($match.Success) {
                $lineNumber = 1 + [regex]::Matches($content.Substring(0, $match.Index), "`n").Count
                $findings.Add("Possible $($rule.Description): ${normalizedPath}:$lineNumber")
            }
        }
    }

    $workflowFiles = @(
        $trackedFiles | Where-Object { $_.Replace('\', '/') -match '^\.github/workflows/[^/]+\.ya?ml$' }
    )

    foreach ($workflowFile in $workflowFiles) {
        $normalizedPath = $workflowFile.Replace('\', '/')
        $workflowText = [System.IO.File]::ReadAllText((Join-Path $repoRoot $workflowFile))

        if ($workflowText -match '(?m)^\s*pull_request_target\s*:') {
            $findings.Add("Unsafe pull_request_target trigger: $normalizedPath")
        }

        $usesMatches = [regex]::Matches(
            $workflowText,
            '(?m)^\s*(?:-\s*)?uses:\s*["'']?([^#\s"'']+)'
        )
        foreach ($usesMatch in $usesMatches) {
            $actionReference = $usesMatch.Groups[1].Value
            if ($actionReference.StartsWith('./')) {
                continue
            }
            if ($actionReference -notmatch '@[0-9a-f]{40}$') {
                $findings.Add("Unpinned external action '$actionReference': $normalizedPath")
            }
        }

        if (
            $workflowText -match 'actions/checkout@' -and
            $workflowText -notmatch '(?m)^\s*persist-credentials:\s*false\s*$'
        ) {
            $findings.Add("Checkout credentials are not explicitly disabled: $normalizedPath")
        }
    }
}
finally {
    Pop-Location
}

if ($findings.Count -gt 0) {
    Write-Error ("Repository policy checks failed:`n - " + ($findings -join "`n - "))
    exit 1
}

Write-Host 'Repository policy checks passed.'
