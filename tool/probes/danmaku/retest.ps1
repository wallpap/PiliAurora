[CmdletBinding()]
param(
    [ValidateSet('all', 'windows', 'android')]
    [string]$Platform = 'all',
    [string]$PresentMonPath,
    [string]$Media24,
    [string]$Media60,
    [string]$AdbPath = 'adb',
    [string]$DeviceId,
    [string]$FlutterSdk,
    [string]$AndroidSdk,
    [string]$RestoreApk,
    [string]$OutputDirectory,
    [switch]$SkipRegression
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$windows = $Platform -in @('all', 'windows')
$android = $Platform -in @('all', 'android')
if ($windows -and -not $PresentMonPath) { throw 'Windows 采集需要 -PresentMonPath。' }
if ($android -and (-not $DeviceId -or -not $FlutterSdk -or -not $AndroidSdk)) {
    throw 'Android 采集需要 -DeviceId、-FlutterSdk 和 -AndroidSdk。'
}
if ($android -and (-not $Media24 -or -not $Media60)) { throw 'Android 点播矩阵需要 -Media24 和 -Media60。' }
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $workspace ('build/danmaku-retest/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "输出目录已存在：$output" }
New-Item -ItemType Directory -Path $output | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
Push-Location $workspace
try {
    if (-not $SkipRegression) {
        & fvm flutter test --no-pub test/pages/danmaku/frame_rate_ticker_test.dart `
            test/pages/danmaku/native_video_frame_sync_test.dart test/pages/danmaku/frame_cadence_test.dart `
            test/pages/danmaku/frame_rate_diagnostics_test.dart test/pages/danmaku/frame_plan_identity_test.dart `
            test/pages/danmaku/frame_deadline_replay_test.dart test/pages/danmaku/frame_late_delivery_test.dart `
            test/pages/danmaku/video_presentation_cadence_test.dart test/pages/danmaku/window_screen_test.dart `
            test/pages/danmaku/live_layer_test.dart test/plugin/pl_player/android/raster_scheduling_test.dart `
            test/plugin/pl_player/playback/native_media_clock_sampling_test.dart `
            tool/experiments/danmaku/frame_cadence_device_matrix_test.dart
        $results.Add(@{ step = 'flutter'; passed = ($LASTEXITCODE -eq 0) })
        & pwsh -NoProfile -File tool/run-native-probes.ps1
        $results.Add(@{ step = 'native'; passed = ($LASTEXITCODE -eq 0) })
        & python -m unittest discover -s tool/probes/android -p '*_test.py' -v
        $results.Add(@{ step = 'android-tools'; passed = ($LASTEXITCODE -eq 0) })
        & python -m unittest discover -s tool/probes/windows -p danmaku_frame_pacing_analysis_test.py -v
        $results.Add(@{ step = 'windows-tools'; passed = ($LASTEXITCODE -eq 0) })
    }
    # 设备采集串行执行，减少另一端解码与GPU负载对Windows采样的干扰。
    if ($windows) {
        $engine = Join-Path $output 'windows-engine'
        & python third_party/flutter_engine/package.py unpack --target windows-x64 --output $engine
        if ($LASTEXITCODE -ne 0) { throw 'Windows 预编译引擎校验失败。' }
        $library = Join-Path $engine 'flutter_windows.dll'
        foreach ($variant in @('plain', 'video')) {
            $options = @('-PresentMonPath', $PresentMonPath, '-Mode', 'release', '-EngineLibrary', $library,
                '-OutputDirectory', (Join-Path $output "windows-$variant"))
            if ($variant -eq 'video') {
                if (-not $Media60) { continue }
                $options += @('-Media', $Media60, '-SkipBuild')
            }
            & pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 @options
            $results.Add(@{ step = "windows-$variant"; passed = ($LASTEXITCODE -eq 0) })
        }
        & pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode release -EngineLibrary $library -SkipPubGet
        $results.Add(@{ step = 'restore-windows'; passed = ($LASTEXITCODE -eq 0) })
    }
    if ($android) {
        $options = @('--adb', $AdbPath, '--serial', $DeviceId, '--flutter-sdk', $FlutterSdk,
            '--android-sdk', $AndroidSdk, '--media', $Media24, '--media', $Media60,
            '--output', (Join-Path $output 'android'))
        if ($RestoreApk) { $options += @('--restore-apk', $RestoreApk) }
        & python tool/probes/android/measure_danmaku.py @options
        $results.Add(@{ step = 'android'; passed = ($LASTEXITCODE -eq 0) })
    }
}
finally {
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'steps.json') -Encoding utf8
    Pop-Location
}
if ($results | Where-Object { -not $_.passed }) { exit 1 }
