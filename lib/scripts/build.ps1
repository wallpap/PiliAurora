param(
    [string]$Arg = '',
    [string]$Version = ''
)

try {
    $versionName = $null
    $requestedVersion = $Version.Trim()
    if ($requestedVersion.StartsWith('v')) {
        $requestedVersion = $requestedVersion.Substring(1)
    }
    if ($requestedVersion -and $requestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "invalid version: $Version"
    }

    $versionCode = [int](git rev-list --count HEAD).Trim()

    $commitHash = (git rev-parse HEAD).Trim()

    $updatedContent = foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match '^\s*version:\s*([\d\.]+)') {
            $versionName = if ($requestedVersion) { $requestedVersion } else { $matches[1] }
            if ($Arg -eq 'android' -and -not $requestedVersion) {
                $versionName += '-' + $commitHash.Substring(0, 9)
            }
            "version: $versionName+$versionCode"
        }
        else {
            $line
        }
    }

    if ($null -eq $versionName) {
        throw 'version not found'
    }

    $updatedContent | Set-Content -Path 'pubspec.yaml' -Encoding UTF8

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $data = @{
        'pili.name' = $versionName
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }

    $data | ConvertTo-Json -Compress | Out-File 'pili_release.json' -Encoding UTF8

    Add-Content -Path $env:GITHUB_ENV -Value "version=$versionName+$versionCode"
}
catch {
    Write-Error "Prebuild Error: $($_.Exception.Message)"
    exit 1
}
