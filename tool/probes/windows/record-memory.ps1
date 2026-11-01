[CmdletBinding()]
param(
    [ValidateSet('Start', 'Record', 'Stop', 'Status')]
    [string]$Action = 'Start',
    [string]$Executable,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [ValidateRange(5, 1800)] [int]$Seconds = 300,
    [switch]$Heap
)

$ErrorActionPreference = 'Stop'
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$statusPath = Join-Path $outputPath 'status.json'
$stopPath = Join-Path $outputPath 'stop.request'
if ($Action -eq 'Status') {
    Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
    exit 0
}
if ($Action -eq 'Stop') {
    if (-not (Test-Path -LiteralPath $statusPath)) { throw '没有此目录的采集状态。' }
    [IO.File]::WriteAllText($stopPath, 'stop')
    Write-Host '已请求停止；等待 status.json 变为 completed/failed 并检查 cleanupErrors。'
    exit 0
}

$exePath = (Resolve-Path -LiteralPath $Executable).Path
$exeName = [IO.Path]::GetFileName($exePath)
if ($exeName -notmatch '^PiliAuroraMemory-[0-9a-f]{8,32}\.exe$') {
    throw '只允许独立命名的 PiliAuroraMemory-<8至32位十六进制编号>.exe 测试包。'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Action -eq 'Start') {
    if (Test-Path -LiteralPath $outputPath) { throw '请为本次采集指定一个尚不存在的输出目录。' }
    New-Item -ItemType Directory -Path $outputPath | Out-Null
    # 单引号字面量编码后传给 PowerShell，避免路径成为命令或参数的一部分。
    $scriptLiteral = $PSCommandPath.Replace("'", "''")
    $exeLiteral = $exePath.Replace("'", "''")
    $outputLiteral = $outputPath.Replace("'", "''")
    $heapArgument = if ($Heap) { ' -Heap' } else { '' }
    $command = "& '$scriptLiteral' -Action Record -Executable '$exeLiteral' -OutputDirectory '$outputLiteral' -Seconds $Seconds$heapArgument"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $startOptions = @{
        FilePath = (Get-Command pwsh -ErrorAction Stop).Source
        ArgumentList = @('-NoProfile', '-EncodedCommand', $encoded)
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    if (-not $elevated) { $startOptions.Verb = 'RunAs' }
    try { $worker = Start-Process @startOptions }
    catch { throw "无法启动采集进程：$($_.Exception.Message)" }
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $state = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($state.state -eq 'recording') {
                    Write-Host "采集已就绪（$Seconds 秒上限）。请在普通权限下手动启动：$exePath"
                    Write-Host "输出：$outputPath；结束时用 -Action Stop -OutputDirectory 指向此目录。"
                    exit 0
                }
                if ($state.state -eq 'failed') { throw [InvalidOperationException]::new($state.error) }
            } catch [InvalidOperationException] { throw }
            catch { } # 仅跳过原子替换之前的短暂写入窗口。
        }
        if ($worker.HasExited) { throw '采集进程提前退出，请检查 status.json。' }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    [IO.File]::WriteAllText($stopPath, 'start-timeout')
    throw '45 秒内未就绪，已请求清理；请检查 status.json。'
}

if (-not $elevated) { throw 'Record 需要管理员权限，请使用 Start 触发 UAC。' }
if (-not (Test-Path -LiteralPath $outputPath -PathType Container)) { throw 'Record 需要 Start 创建输出目录。' }
if (Test-Path -LiteralPath $statusPath) { throw '此目录已被其他采集使用。' }
$session = 'PiliAuroraMemory-' + [Guid]::NewGuid().ToString('N')
$wprPath = Join-Path $env:SystemRoot 'System32/wpr.exe'
$ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exeName"
$started = $false
$ownsHeapConfig = $false
$failure = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$metadata = [ordered]@{
    state = 'starting'; session = $session; executable = $exeName
    executableSha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    startedUtc = [DateTime]::UtcNow.ToString('o'); heap = [bool]$Heap
    maximumSeconds = $Seconds
    scope = 'VirtualAllocation is system-wide; heap instrumentation targets only the named probe.'
    trace = 'memory.etl'; cleanupErrors = @()
}
function Save-Status {
    $temporary = Join-Path $outputPath 'status.pending.json'
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}
function Invoke-Wpr([string[]]$WprArguments) {
    $result = & $wprPath @WprArguments 2>&1
    $code = $LASTEXITCODE
    $result | Add-Content -LiteralPath (Join-Path $outputPath 'wpr.log') -Encoding UTF8
    if ($code -ne 0) { throw "wpr $($WprArguments -join ' ') failed ($code)" }
}
Save-Status
try {
    if ($Heap) {
        # 不覆盖已有 IFEO 配置。每次都使用新名字，关闭后撤销本次配置。
        if (Test-Path -LiteralPath $ifeoPath) { throw '此测试程序已有 IFEO 配置，请换一个新编号。' }
        if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exeName)) -ErrorAction SilentlyContinue) {
            throw '堆追踪需在测试程序启动前配置，请先结束此测试实例。'
        }
        $ownsHeapConfig = $true
        Invoke-Wpr -WprArguments @('-heaptracingconfig', $exeName, 'enable')
    }
    $startArguments = @('-start', 'VirtualAllocation')
    if ($Heap) { $startArguments += @('-start', 'Heap') }
    # filemode 避免内存模式随机器内存扩大缓冲池。只控制本次命名实例。
    $startArguments += @('-filemode', '-recordtempto', $outputPath, '-instancename', $session)
    Invoke-Wpr -WprArguments $startArguments
    $started = $true
    $metadata.state = 'recording'
    Save-Status
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $stopPath)) {
        Start-Sleep -Milliseconds 250
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    $metadata.state = 'stopping'
    try { Save-Status } catch { $cleanupErrors.Add($_.Exception.Message) }
    if ($started) {
        try {
            Invoke-Wpr -WprArguments @('-stop', (Join-Path $outputPath 'memory.etl'), '-skipPdbGen', '-instancename', $session)
        } catch {
            $cleanupErrors.Add($_.Exception.Message)
            try { Invoke-Wpr -WprArguments @('-cancel', '-instancename', $session) }
            catch { $cleanupErrors.Add($_.Exception.Message) }
        }
    }
    if ($ownsHeapConfig) {
        try {
            Invoke-Wpr -WprArguments @('-heaptracingconfig', $exeName, 'disable')
            if (Test-Path -LiteralPath $ifeoPath) {
                $key = Get-Item -LiteralPath $ifeoPath
                # WPR disable 保留 TracingFlags=0；此键在本次采集前不存在。
                if ($key.GetValueNames().Count -eq 1 -and
                    $key.GetValueNames()[0] -eq 'TracingFlags' -and
                    $key.GetValue('TracingFlags') -eq 0 -and $key.SubKeyCount -eq 0) {
                    Remove-ItemProperty -LiteralPath $ifeoPath -Name 'TracingFlags'
                    $key = Get-Item -LiteralPath $ifeoPath
                }
                if ($key.GetValueNames().Count -eq 0 -and $key.SubKeyCount -eq 0) {
                    Remove-Item -LiteralPath $ifeoPath
                }
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    $metadata.state = if ($failure -or $cleanupErrors.Count) { 'failed' } else { 'completed' }
    $metadata.error = $failure
    $metadata.cleanupErrors = @($cleanupErrors.ToArray())
    $metadata.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-Status
}
if ($metadata.state -eq 'failed') { exit 1 }
