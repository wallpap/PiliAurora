param(
    [string]$BuildRoot = "build/windows/x64",
    [string]$Configuration = "Debug",
    [string]$CMakePath = ""
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not [IO.Path]::IsPathRooted($BuildRoot)) {
    $BuildRoot = Join-Path $workspace $BuildRoot
}
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$archiveName = "mpv-dev-x86_64-20260819-git-e7191f2a65.7z"
$expectedDll = "7BDA2CEE77F00BD9BE104C590055B44D2F9C5074DE3A6B92F7F1E763FE2B3A6E"
$archive = Join-Path $BuildRoot $archiveName
$module = Join-Path $workspace "third_party/media_kit_libs_windows_video/windows/libmpv.cmake"

if (-not $CMakePath) {
    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) {
        $CMakePath = $command.Source
    } else {
        $line = Select-String -LiteralPath (Join-Path $BuildRoot "CMakeCache.txt") -Pattern '^CMAKE_COMMAND:INTERNAL=(.+)$'
        if ($line -and $line.Line -match '^CMAKE_COMMAND:INTERNAL=(.+)$') {
            $CMakePath = $Matches[1]
        } else {
            throw "CMake not found. Pass -CMakePath or build Windows once."
        }
    }
}

# 验证实际打包的 DLL，不能只验证下载版本。
$bundledDll = Join-Path $BuildRoot "runner/$Configuration/libmpv-2.dll"
if ((Get-FileHash -LiteralPath $bundledDll -Algorithm SHA256).Hash -ne $expectedDll) {
    throw "Bundled libmpv is not the pinned build: $bundledDll"
}
Write-Host "PASS: bundled DLL is the pinned 20260819 build"

$fixtureBase = Join-Path $workspace "build"
$fixture = Join-Path $fixtureBase ("libmpv-verification-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    Copy-Item -LiteralPath $archive -Destination $fixture
    $cachedDll = Join-Path $fixture "libmpv/libmpv-2.dll"
    New-Item -ItemType Directory -Path (Split-Path $cachedDll -Parent) | Out-Null
    Set-Content -LiteralPath $cachedDll -Value "stale DLL in a non-empty build directory"
    $script = Join-Path $fixture "check.cmake"
    Set-Content -LiteralPath $script -Value @(
        ('set(CMAKE_BINARY_DIR "' + $fixture.Replace('\', '/') + '")'),
        ('include("' + $module.Replace('\', '/') + '")')
    )
    & $CMakePath -P $script
    if ($LASTEXITCODE -ne 0) { throw "Cache migration failed" }
    if ((Get-FileHash -LiteralPath $cachedDll -Algorithm SHA256).Hash -ne $expectedDll) {
        throw "Stale non-empty cache survived libmpv configuration"
    }
    Write-Host "PASS: stale non-empty cache is replaced"

    & $CMakePath -P $script
    if ($LASTEXITCODE -ne 0) { throw "Repeated configuration failed" }
    Write-Host "PASS: repeated configuration succeeds"

    Set-Content -LiteralPath (Join-Path $fixture $archiveName) -Value "corrupt archive"
    $output = (& $CMakePath -P $script 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -or $output -notmatch 'libmpv SHA256 mismatch') {
        throw "Corrupt archive was not rejected by SHA256 verification"
    }
    Write-Host "PASS: corrupt archive fails before extraction"
} finally {
    # 仅清理本脚本创建的 build 子目录，先验证绝对路径边界。
    $resolvedFixture = (Resolve-Path -LiteralPath $fixture).Path
    $resolvedBase = (Resolve-Path -LiteralPath $fixtureBase).Path.TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($resolvedBase, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedFixture -Leaf) -notlike 'libmpv-verification-*') {
        throw "Refusing to clean unexpected verification directory: $resolvedFixture"
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
