[CmdletBinding()]
param(
    [switch]$SkipPatch,
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$inheritedDev = $env:PILIAURORA_TEST_RELEASE

try {
    # 复用 release 的 dev 配置，以独立包名与正式应用并存。
    $env:PILIAURORA_TEST_RELEASE = "true"
    $buildOptions = @()
    if ($SkipPatch) { $buildOptions += "-SkipPatch" }
    if ($SkipPubGet) { $buildOptions += "-SkipPubGet" }
    if ($VerbosePreference -eq "Continue") { $buildOptions += "-Verbose" }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot "build.ps1") `
        -Platform android -Mode release -Abi arm64-v8a @buildOptions
    if ($LASTEXITCODE -ne 0) {
        throw "Android 测试包构建失败，退出码：$LASTEXITCODE"
    }

    $metadata = Get-Content -LiteralPath (Join-Path $workspace "build/app/outputs/apk/release/output-metadata.json") `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($metadata.applicationId -ne "io.github.wallpap.piliaurora.dev") {
        throw "测试包包名不符合预期：$($metadata.applicationId)"
    }
    $source = Join-Path $workspace "build/app/outputs/flutter-apk/app-release.apk"
    $archive = [IO.Compression.ZipFile]::OpenRead($source)
    try {
        $abis = @($archive.Entries.FullName | ForEach-Object {
            if ($_ -match '^lib/([^/]+)/') { $Matches[1] }
        } | Sort-Object -Unique)
        if ($abis.Count -ne 1 -or $abis[0] -ne "arm64-v8a") {
            throw "测试包 ABI 不符合预期：$($abis -join ', ')"
        }
    }
    finally { $archive.Dispose() }

    $outputDirectory = Join-Path $workspace "build/android-test"
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $output = Join-Path $outputDirectory "PiliAurora-dev-arm64-v8a-release.apk"
    Copy-Item -LiteralPath $source `
        -Destination $output -Force
    Copy-Item -LiteralPath ([IO.Path]::ChangeExtension($source, '.json')) `
        -Destination ([IO.Path]::ChangeExtension($output, '.json')) -Force
    Write-Host "测试包：$output"
    Write-Host "包名：io.github.wallpap.piliaurora.dev（PiliAurora dev）"
    Write-Host "SHA256：$((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
}
finally {
    if ($null -eq $inheritedDev) {
        Remove-Item Env:PILIAURORA_TEST_RELEASE -ErrorAction SilentlyContinue
    }
    else {
        $env:PILIAURORA_TEST_RELEASE = $inheritedDev
    }
}
