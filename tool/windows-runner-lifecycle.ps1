param([string]$CMake = 'cmake', [switch]$SkipFlutterBuild)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$build = Join-Path $root 'build/runner-lifecycle-tests'
$profile = Join-Path $root 'build/windows/x64/runner/Profile'
if (-not $SkipFlutterBuild) {
    Push-Location -LiteralPath $root
    try {
        & flutter build windows --profile --no-pub --target tool/windows_runner_lifecycle_fixture.dart
        if ($LASTEXITCODE -ne 0) { throw 'Flutter fixture build failed.' }
    } finally {
        Pop-Location
    }
}
$config = Join-Path $root 'windows/flutter/ephemeral/generated_config.cmake'
if (-not (Select-String -LiteralPath $config -SimpleMatch 'FLUTTER_TARGET=tool/windows_runner_lifecycle_fixture.dart')) {
    throw 'Profile assets are not the lifecycle fixture. Run without -SkipFlutterBuild.'
}
if (-not (Get-Command $CMake -ErrorAction SilentlyContinue)) {
    $cache = Join-Path $root 'build/windows/x64/CMakeCache.txt'
    $entry = Select-String -LiteralPath $cache -Pattern '^CMAKE_COMMAND:INTERNAL=(.+)$'
    if (-not $entry) { throw 'CMake not found. Pass its absolute path with -CMake.' }
    $CMake = $entry.Matches[0].Groups[1].Value
}
foreach ($path in @('flutter_windows.dll', 'data/icudtl.dat', 'data/app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $profile $path))) {
        throw 'First build a Windows Profile target with Flutter.'
    }
}
& $CMake -S (Join-Path $root 'test/windows/runner') -B $build -A x64
if ($LASTEXITCODE -ne 0) { throw 'Native test configuration failed.' }
& $CMake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native test build failed.' }
$exe = Join-Path $build 'Release/runner_lifecycle_test.exe'
# main.cpp 的相对 data 路径按测试 EXE 所在目录解析。
$data = Join-Path $profile 'data'
$link = Join-Path $build 'Release/data'
if (-not (Test-Path -LiteralPath $link)) {
    New-Item -ItemType Junction -Path $link -Target $data | Out-Null
} elseif ((Get-Item -LiteralPath $link).Target -ne $data) {
    throw 'Test data path already exists and does not refer to the Profile data.'
}
# 仅测试进程使用已有引擎 DLL，不复制或改动共享缓存。
$previousPath = $env:PATH
try {
    $env:PATH = "$profile;$previousPath"
    foreach ($case in @('font-after-destroy', 'scope-destroy', 'main-return')) {
        & $exe (Join-Path $profile 'data') $case
        if ($LASTEXITCODE -ne 0) { throw "Runner lifecycle regression failed: $case ($LASTEXITCODE)" }
    }
} finally {
    $env:PATH = $previousPath
}
