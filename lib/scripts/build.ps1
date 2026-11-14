param(
    [string]$Arg = '',
    [string]$Version = '',
    [switch]$MetadataOnly
)

try {
    $versionName = $null
    $requestedVersion = $Version.Trim()
    if ($requestedVersion.StartsWith('v')) {
        $requestedVersion = $requestedVersion.Substring(1)
    }
    $versionPattern = '\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?'
    if ($requestedVersion -and $requestedVersion -notmatch "^$versionPattern`$") {
        throw "invalid version: $Version"
    }

    $shallow = git rev-parse --is-shallow-repository
    if ($LASTEXITCODE -ne 0) { throw '版本生成需要 Git 工作区。' }
    if ($shallow.Trim() -eq 'true') { throw '版本生成需要完整 Git 历史，请先运行 git fetch --unshallow。' }
    $count = git rev-list --count HEAD
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 提交数。' }
    $versionCode = [int]$count.Trim()
    $commitHash = git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 提交。' }
    $commitHash = $commitHash.Trim()

    $updatedContent = foreach ($line in (Get-Content -Path 'pubspec.yaml' -Encoding UTF8)) {
        if ($line -match "^\s*version:\s*($versionPattern)(?:\+\d+)?\s*`$") {
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

    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $data = @{
        'pili.name' = $versionName
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }

    # 本地构建只读取元数据，通过 Flutter 参数设置版本，避免改写工作区。
    if ($MetadataOnly) { return $data }

    $updatedContent | Set-Content -Path 'pubspec.yaml' -Encoding UTF8
    $data | ConvertTo-Json -Compress | Out-File 'pili_release.json' -Encoding UTF8
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "version=$versionName+$versionCode"
    }
}
catch {
    Write-Error "Prebuild Error: $($_.Exception.Message)"
    exit 1
}
