[CmdletBinding()]
param(
    [ValidateSet("android", "windows")]
    [string]$Platform = "windows",
    [ValidateSet("debug", "profile", "release")]
    [string]$Mode = "release",
    [ValidateSet("armeabi-v7a", "arm64-v8a", "x86_64")]
    [string]$Abi,
    [Alias('WindowsEngineLibrary')]
    [string]$EngineLibrary,
    [string]$FlutterSdk,
    [string]$AndroidSdk,
    [string]$Target = 'lib/main.dart',
    [string]$Output,
    [string[]]$DartDefine = @(),
    [switch]$DevRelease,
    [string]$SourceApk,
    [switch]$SkipPatch,
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
$Workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Workspace

if ($Abi -and $Platform -ne "android") {
    throw "-Abi 仅适用于 Android 构建。"
}
if ($Mode -eq 'profile' -and -not $EngineLibrary) {
    throw 'Profile 需要同模式的引擎产物；日常验收请使用默认 Release，调试使用 -Mode debug。'
}
if ($Platform -ne 'android' -and ($FlutterSdk -or $AndroidSdk -or $DevRelease -or $SourceApk -or $Output)) {
    throw 'SDK、dev 包、复用 APK 和输出参数仅适用于 Android 装配。'
}
if ($DevRelease -and ($Mode -ne 'release' -or ($Abi -and $Abi -ne 'arm64-v8a'))) {
    throw '-DevRelease 要求 arm64-v8a Release。'
}
if (-not $EngineLibrary) {
    if ($FlutterSdk -or $SourceApk) { throw '-FlutterSdk 和 -SourceApk 用于验证维护中的 Android 引擎。' }
    if ($Output -and ($Mode -ne 'release' -or -not $Abi)) { throw '-Output 要求 Release 且指定单个 -Abi。' }
}

# 与发布 CI 共用版本生成规则；pubspec 只提供版本名，构建号来自完整 Git 历史。
$versionMatch = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $Workspace 'pubspec.yaml')), '(?m)^version:\s*([^\s+]+)(?:\+(\d+))?\s*$')
if (-not $versionMatch.Success) { throw 'pubspec.yaml 缺少有效版本。' }
$buildMetadata = & (Join-Path $Workspace 'lib/scripts/build.ps1') -Version $versionMatch.Groups[1].Value -MetadataOnly
$providedKeys = @($DartDefine | ForEach-Object { $_.Split('=')[0] })
foreach ($key in $buildMetadata.Keys) {
    if ($key -notin $providedKeys) { $DartDefine += "$key=$($buildMetadata[$key])" }
}
$effectiveMetadata = @{}
foreach ($define in $DartDefine) {
    $parts = $define.Split('=', 2)
    if ($parts.Length -eq 2) { $effectiveMetadata[$parts[0]] = $parts[1] }
}

$engineProfile = 'standard'
$windowsEnginePath = $null
if ($EngineLibrary) {
    if ($Mode -eq 'debug') { throw '自编引擎适用于 Profile/Release 构建。' }
    if ($Platform -eq 'android') {
        if (-not $FlutterSdk -or -not $AndroidSdk) { throw 'Android 自编构建需要 -FlutterSdk 和 -AndroidSdk。' }
        if ($DevRelease -and $Mode -ne 'release') { throw '-DevRelease 要求 -Mode release。' }
        $builder = Join-Path $PSScriptRoot 'engine/frame_plan/build_apk.py'
        $customMode = if ($DevRelease) { 'dev-release' } else { $Mode }
        $customArguments = @($builder, '--flutter-sdk', $FlutterSdk, '--engine-library', $EngineLibrary,
            '--android-sdk', $AndroidSdk, '--mode', $customMode, '--target', $Target)
        if ($Abi) { $customArguments += @('--abi', $Abi) }
        if ($Output) { $customArguments += @('--output', $Output) }
        if ($SourceApk) { $customArguments += @('--skip-build', '--source-apk', $SourceApk) }
        if ($SkipPatch) { $customArguments += '--skip-patch' }
        if ($SkipPubGet) { $customArguments += '--skip-pub-get' }
        foreach ($define in $DartDefine) { $customArguments += "--dart-define=$define" }
        & python @customArguments
        if ($LASTEXITCODE -ne 0) { throw 'Android 自编引擎装配失败。' }
        exit 0
    }
    $engineProfile = 'windowsDwmPaced'
    $windowsEnginePath = (Resolve-Path -LiteralPath $EngineLibrary).Path
}
foreach ($define in $DartDefine) {
    if ($define.Split('=')[0] -in @('PILIAURORA_PRESENTATION_PROFILE', 'PILIAURORA_ENGINE_IDENTITY', 'PILIAURORA_CONTENT_COMPOSITION')) {
        throw '呈现配置参数由构建入口生成。'
    }
}

$dart = Get-Command dart -ErrorAction SilentlyContinue
if (-not $dart) {
    throw "Dart is required to run FVM. Install Dart or add the Flutter SDK declared in .fvmrc to PATH."
}

$fvm = Get-Command fvm -ErrorAction SilentlyContinue
if (-not $fvm) {
    throw "FVM is required. Install FVM and the Flutter version declared in .fvmrc."
}

# Run FVM through the Dart executable on PATH. This avoids loading a global
# FVM snapshot compiled by a different Dart version. The exec subcommand also
# puts the selected Flutter SDK's Dart executable first in PATH for asset hooks.
$fvmEntryPoint = @("pub", "global", "run", "fvm:main")

function Invoke-Fvm {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Quiet
    )

    if ($Quiet) {
        $output = & $dart.Source @fvmEntryPoint @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $output | ForEach-Object { Write-Host $_ }
        }
        else {
            $output | ForEach-Object { Write-Verbose $_ }
        }
    }
    else {
        & $dart.Source @fvmEntryPoint @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "FVM command failed with exit code $($LASTEXITCODE): fvm $($Arguments -join ' ')"
    }
}

function Resolve-FvmFlutterRoot {
    $flutterExecutable = & $dart.Source @fvmEntryPoint "exec" "pwsh" "-NoProfile" "-Command" "(Get-Command flutter).Source" |
        Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($flutterExecutable)) {
        throw "Unable to resolve the Flutter SDK selected by FVM."
    }

    $flutterExecutable = $flutterExecutable.ToString().Trim()
    if (-not (Test-Path $flutterExecutable)) {
        throw "FVM resolved a missing Flutter executable: $flutterExecutable"
    }

    return (Resolve-Path (Join-Path (Split-Path $flutterExecutable -Parent) "..")).Path
}

if ($Platform -eq "android") {
    # Gradle 启动器在 JDK 25 下加载原生库需要显式启用原生访问。
    $env:JAVA_OPTS = (@($env:JAVA_OPTS, "--enable-native-access=ALL-UNNAMED") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
    $gradleTemp = Join-Path $Workspace ".gradle-tmp"
    New-Item -ItemType Directory -Force $gradleTemp | Out-Null
    $env:TEMP = $gradleTemp
    $env:TMP = $gradleTemp
}

$proxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:HTTP_PROXY }
if ($proxy -and $proxy -match '^(?:https?://)?(?<host>[^:/]+):(?<port>\d+)$') {
    $proxyOptions = @(
        "-Dhttp.proxyHost=$($Matches.host)",
        "-Dhttp.proxyPort=$($Matches.port)",
        "-Dhttps.proxyHost=$($Matches.host)",
        "-Dhttps.proxyPort=$($Matches.port)"
    ) -join " "
    $env:JAVA_TOOL_OPTIONS = (($env:JAVA_TOOL_OPTIONS, $proxyOptions) -ne $null -join " ").Trim()
}

if (-not $SkipPubGet) {
    Invoke-Fvm -Arguments @("exec", "flutter", "pub", "get", "--enforce-lockfile") -Quiet
    Write-Host "依赖解析完成。"
}
elseif (-not (Test-Path -LiteralPath (Join-Path $Workspace ".dart_tool/package_config.json"))) {
    throw "依赖尚未准备，请先运行构建脚本而不传 -SkipPubGet。"
}

if (-not $SkipPatch) {
    $patchScript = Join-Path $Workspace "lib/scripts/patch.ps1"
    $selectedFlutterRoot = Resolve-FvmFlutterRoot
    $inheritedFlutterRoot = $env:FLUTTER_ROOT
    $inheritedPath = $env:PATH
    $env:FLUTTER_ROOT = $selectedFlutterRoot
    $env:PATH = "$(Join-Path $selectedFlutterRoot 'bin');$inheritedPath"
    try {
        [string[]]$patchOptions = if ($VerbosePreference -eq "Continue") { @("-Verbose") } else { @() }
        & pwsh -NoProfile -File $patchScript $Platform -SkipPubGet @patchOptions
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter patch step failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if ($null -eq $inheritedFlutterRoot) {
            Remove-Item Env:FLUTTER_ROOT -ErrorAction SilentlyContinue
        }
        else {
            $env:FLUTTER_ROOT = $inheritedFlutterRoot
        }
        $env:PATH = $inheritedPath
    }
}

# 解析及补丁步骤结束后检查最终锁文件，禁止重新引入 Git 来源。
Invoke-Fvm @("exec", "dart", "--packages=.dart_tool/package_config.json", "tool/check_dependencies.dart")

$selectedFlutterRoot = Resolve-FvmFlutterRoot
# Release 与发布 CI 共用已验收的引擎；缺少或失配时直接失败，避免悄悄换回原版。
if ($Mode -eq 'release' -and -not $EngineLibrary) {
    $packageScript = Join-Path $Workspace 'third_party/flutter_engine/package.py'
    if ($Platform -eq 'android') {
        if (-not $AndroidSdk) { $AndroidSdk = $env:ANDROID_HOME }
        if (-not $AndroidSdk) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
        if (-not $AndroidSdk -and (Test-Path 'android/local.properties')) {
            $sdkLine = Get-Content 'android/local.properties' | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
            if ($sdkLine) { $AndroidSdk = $sdkLine.Substring(8).Replace('\\', '\').Replace('\:', ':') }
        }
        if (-not $AndroidSdk) { throw '未找到 Android SDK；设置 ANDROID_HOME 或传入 -AndroidSdk。' }
        $abis = if ($Abi) { @($Abi) } elseif ($DevRelease -or $env:PILIAURORA_TEST_RELEASE -eq 'true') { @('arm64-v8a') } else { @('armeabi-v7a', 'arm64-v8a', 'x86_64') }
        foreach ($buildAbi in $abis) {
            $arch = @{ 'armeabi-v7a' = 'arm'; 'arm64-v8a' = 'arm64'; 'x86_64' = 'x64' }[$buildAbi]
            $engineDirectory = Join-Path $Workspace "build/prebuilt-engine/android-$arch"
            & python $packageScript unpack --target "android-$arch" --output $engineDirectory | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Android 引擎校验失败：$buildAbi" }
            $customMode = if ($DevRelease -or $env:PILIAURORA_TEST_RELEASE -eq 'true') { 'dev-release' } else { 'release' }
            $apkOutput = if ($Output) { $Output } elseif ($customMode -eq 'dev-release') { "build/android-test/PiliAurora-dev-$buildAbi-release.apk" } else { "build/release-apks/PiliAurora-android-$buildAbi-release.apk" }
            $apkArguments = @((Join-Path $PSScriptRoot 'engine/frame_plan/build_apk.py'),
                '--flutter-sdk', $selectedFlutterRoot, '--android-sdk', $AndroidSdk,
                '--engine-library', (Join-Path $engineDirectory 'libflutter.so'),
                '--mode', $customMode, '--abi', $buildAbi, '--target', $Target,
                '--output', $apkOutput, '--skip-patch', '--skip-pub-get')
            foreach ($define in $DartDefine) { $apkArguments += "--dart-define=$define" }
            & python @apkArguments
            if ($LASTEXITCODE -ne 0) { throw "Android APK 装配失败：$buildAbi" }
            # 单架构入口保留 Flutter 的稳定输出，供独立测试包脚本使用。
            if ($abis.Count -eq 1) {
                $flutterApk = Join-Path $Workspace 'build/app/outputs/flutter-apk/app-release.apk'
                if ([IO.Path]::GetFullPath($apkOutput) -ne $flutterApk) {
                    Copy-Item -LiteralPath $apkOutput -Destination $flutterApk -Force
                    Copy-Item -LiteralPath ([IO.Path]::ChangeExtension($apkOutput, '.json')) -Destination ([IO.Path]::ChangeExtension($flutterApk, '.json')) -Force
                }
            }
        }
        exit 0
    }
    $engineDirectory = Join-Path $Workspace 'build/prebuilt-engine/windows-x64'
    & python $packageScript unpack --target windows-x64 --output $engineDirectory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows 引擎校验失败。' }
    $engineProfile = 'windowsDwmPaced'
    $windowsEnginePath = Join-Path $engineDirectory 'flutter_windows.dll'
}

$identityArguments = @((Join-Path $PSScriptRoot 'engine/engine_identity.py'), '--profile', $engineProfile,
    '--mode', $Mode, '--flutter-sdk', $selectedFlutterRoot)
if ($windowsEnginePath) { $identityArguments += @('--library', $windowsEnginePath) }
$configurationJson = & python @identityArguments
if ($LASTEXITCODE -ne 0) { throw '构建引擎身份校验失败。' }
$presentationConfiguration = $configurationJson | ConvertFrom-Json
if ($Platform -eq 'windows' -and $Mode -eq 'release' -and $windowsEnginePath) {
    $configurationJson | Set-Content -LiteralPath (Join-Path $Workspace 'build/windows-engine-config.json') -Encoding utf8NoBOM
}

$buildTarget = if ($Platform -eq "android") { "apk" } else { "windows" }
$buildArguments = @("exec", "flutter", "build", $buildTarget, "--$Mode")
# Flutter 的动画状态行固定占用 72 列（含首帧）；窄终端在最后一列写入
# 进度字符后会触发自动换行，退格刷新也无法回到上一行，表现为光标错位。
# 只在确实放不下状态行时关闭颜色/动画，宽终端仍保留正常的进度显示。
$terminalWidth = 0
try {
    $terminalWidth = [int]$Host.UI.RawUI.WindowSize.Width
}
catch {
    # 非交互终端没有窗口尺寸，交给 Flutter 自己判断输出模式。
}
if ($terminalWidth -gt 0 -and $terminalWidth -le 72) {
    $buildArguments += '--no-color'
}
if ($Abi) {
    $targetPlatform = switch ($Abi) {
        "armeabi-v7a" { "android-arm" }
        "arm64-v8a" { "android-arm64" }
        "x86_64" { "android-x64" }
    }
    $buildArguments += "--target-platform=$targetPlatform"
}
$buildArguments += @('--no-pub', "--target=$Target")
$buildArguments += @("--build-name=$($effectiveMetadata['pili.name'])", "--build-number=$($effectiveMetadata['pili.code'])")
foreach ($define in @($presentationConfiguration.dartDefines) + $DartDefine) {
    $buildArguments += "--dart-define=$define"
}
Invoke-Fvm -Arguments $buildArguments

if ($Platform -eq 'windows') {
    $modeDirectory = @{ debug = 'Debug'; profile = 'Profile'; release = 'Release' }[$Mode]
    $runnerDirectory = Join-Path $Workspace "build/windows/x64/runner/$modeDirectory"
    $outputIdentityPath = Join-Path $runnerDirectory 'engine-identity.json'
    if ($windowsEnginePath) {
        $verifiedJson = & python @identityArguments
        if ($LASTEXITCODE -ne 0) { throw '构建后引擎身份校验失败。' }
        $verified = $verifiedJson | ConvertFrom-Json
        if ($verified.identityDigest -ne $presentationConfiguration.identityDigest) { throw '构建期间引擎身份发生变化。' }
        $identity = $verified.identity
        $destination = Join-Path $runnerDirectory 'flutter_windows.dll'
        Copy-Item -LiteralPath $windowsEnginePath -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $identity.binarySha256) {
            throw '输出目录的自编引擎摘要不匹配。'
        }
        $identity | Add-Member -NotePropertyName identityDigest -NotePropertyValue $presentationConfiguration.identityDigest
        $identity | Add-Member -NotePropertyName application -NotePropertyValue @{
            target = $Target
            binarySha256 = (Get-FileHash -LiteralPath (Join-Path $runnerDirectory 'PiliAurora.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $identity | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputIdentityPath -Encoding utf8
        Write-Host "已装配固定 Windows 引擎：$($identity.binarySha256)"
    }
    else {
        & python @identityArguments --verify-standard-output $runnerDirectory --platform windows | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '标准 Windows 输出核对失败。' }
    }
}

if ($Platform -eq 'android') {
    $apkPath = Join-Path $Workspace "build/app/outputs/flutter-apk/app-$Mode.apk"
    & python @identityArguments --verify-standard-output $apkPath --platform android | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '标准 Android 输出核对失败。' }
}
