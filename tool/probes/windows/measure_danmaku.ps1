[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PresentMonPath,
    [string]$Media,
    [string]$EngineLibrary,
    [ValidateSet('profile', 'release')]
    [string]$Mode = 'profile',
    [string]$OutputDirectory,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$presentMon = (Resolve-Path -LiteralPath $PresentMonPath).Path
$mediaPath = if ($Media) { (Resolve-Path -LiteralPath $Media).Path } else { $null }
$enginePath = if ($EngineLibrary) { (Resolve-Path -LiteralPath $EngineLibrary).Path } else { $null }
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $workspace ('build/windows-danmaku-validation/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputPath) {
    throw "输出目录已存在，请选择新目录：$outputPath"
}
New-Item -ItemType Directory -Path $outputPath | Out-Null

Push-Location $workspace
$probeProcess = $null
$captureProcess = $null
$sessionName = 'PiliAuroraDanmaku-' + [Guid]::NewGuid().ToString('N')
try {
    if (-not $SkipBuild) {
        $buildOptions = @('-Platform', 'windows', '-Mode', $Mode, '-Target', 'tool/probes/windows/danmaku_frame_pacing.dart', '-SkipPubGet')
        if ($enginePath) { $buildOptions += @('-EngineLibrary', $enginePath) }
        & pwsh -NoProfile -File (Join-Path $workspace 'tool/build.ps1') @buildOptions
        if ($LASTEXITCODE -ne 0) { throw 'Windows 探针构建失败。' }
    }
    $modeDirectory = (Get-Culture).TextInfo.ToTitleCase($Mode)
    $binary = Join-Path $workspace "build/windows/x64/runner/$modeDirectory/PiliAurora.exe"
    $identityFile = Join-Path (Split-Path $binary -Parent) 'engine-identity.json'
    if ($enginePath) {
        . (Join-Path $workspace 'tool/engine/windows_frame_pacing/engine_identity.ps1')
        $expected = Get-WindowsFramePacingEngineIdentity -LibraryPath $enginePath -Mode $Mode
        $installed = Get-WindowsFramePacingEngineIdentity -LibraryPath (Join-Path (Split-Path $binary -Parent) 'flutter_windows.dll') -Mode $Mode
        if ($expected.binarySha256 -ne $installed.binarySha256) { throw '探针应用配置与引擎身份不匹配，请重新构建。' }
        Copy-Item -LiteralPath $identityFile -Destination (Join-Path $outputPath 'engine-identity.json')
    }
    elseif (Test-Path -LiteralPath $identityFile) { throw '标准探针输出仍包含自编引擎身份，请重新构建。' }
    $report = Join-Path $outputPath 'probe.json'
    $csv = Join-Path $outputPath 'presentmon.csv'
    $probeArguments = @('"' + $report + '"')
    if ($mediaPath) { $probeArguments += '"' + $mediaPath + '"' }
    $probeProcess = Start-Process -FilePath $binary -ArgumentList $probeArguments -WorkingDirectory $workspace `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $outputPath 'probe.stdout.log') `
        -RedirectStandardError (Join-Path $outputPath 'probe.stderr.log')
    $captureArguments = @('--process_id', $probeProcess.Id, '--session_name', $sessionName,
        '--output_file', ('"' + $csv + '"'), '--qpc_time', '--v1_metrics', '--no_track_input',
        '--no_console_stats', '--timed', '120', '--terminate_after_timed', '--terminate_on_proc_exit')
    $captureProcess = Start-Process -FilePath $presentMon -ArgumentList $captureArguments `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $outputPath 'presentmon.stdout.log') `
        -RedirectStandardError (Join-Path $outputPath 'presentmon.stderr.log')
    Write-Host "正在采集四组弹幕，报告目录：$outputPath"
    $deadline = [DateTime]::UtcNow.AddSeconds(110)
    while (-not $probeProcess.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw '探针未在 110 秒内完成。' }
        if ($captureProcess.HasExited -and $captureProcess.ExitCode -ne 0) {
            throw "PresentMon 采集失败，退出码 $($captureProcess.ExitCode)，请查看 presentmon.stderr.log。"
        }
    }
    if (-not $captureProcess.WaitForExit(8000)) {
        # 仅停止本次创建的独立 ETW session，保留其他采集会话。
        & $presentMon --session_name $sessionName --terminate_existing_session | Out-Null
        if (-not $captureProcess.WaitForExit(8000)) { throw 'PresentMon 未完成 CSV 写入。' }
    }
    if ($captureProcess.ExitCode -ne 0) { throw 'PresentMon 未正常结束。' }
    if (-not (Test-Path -LiteralPath $report)) {
        throw "探针退出码为 $($probeProcess.ExitCode)，未生成 probe.json，请查看 probe.stderr.log。"
    }
    if (-not (Test-Path -LiteralPath $csv)) {
        throw 'PresentMon 未生成 CSV，请查看 presentmon.stderr.log。'
    }
    & python (Join-Path $PSScriptRoot 'danmaku_frame_pacing_analysis.py') $report $csv --output $outputPath
    if ($LASTEXITCODE -ne 0) { throw "帧连续性判定未通过，请查看 $outputPath/summary.md。" }
    Write-Host "采集、关联和 ±1/±2/±3 判定通过：$outputPath/summary.md"
}
finally {
    if ($probeProcess -and -not $probeProcess.HasExited) {
        $probeProcess.Kill()
        $null = $probeProcess.WaitForExit(5000)
    }
    if ($captureProcess -and -not $captureProcess.HasExited) {
        & $presentMon --session_name $sessionName --terminate_existing_session | Out-Null
        if (-not $captureProcess.WaitForExit(5000)) { $captureProcess.Kill() }
    }
    Pop-Location
}
