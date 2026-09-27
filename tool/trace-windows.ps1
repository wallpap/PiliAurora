param(
    [int]$ProcessId,
    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 180,
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 2,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP ("pili_aurora-trace-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

if (-not $PSBoundParameters.ContainsKey('ProcessId')) {
    $matches = @(Get-CimInstance Win32_Process -Filter "name = 'PiliAurora.exe'")
    if ($matches.Count -ne 1) {
        throw "Expected one PiliAurora process, found $($matches.Count). Pass -ProcessId."
    }
    $ProcessId = $matches[0].ProcessId
}

$target = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
if (-not $target -or $target.Name -ne 'PiliAurora.exe') {
    throw "Process $ProcessId is not PiliAurora.exe."
}

$samples = [System.Collections.Generic.List[object]]::new()
$deadline = (Get-Date).AddSeconds($DurationSeconds)
$previousCpu = $null
$previousTime = $null

while ((Get-Date) -lt $deadline) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { break }

    $now = Get-Date
    $cpuSeconds = $process.CPU
    $cpuPercent = $null
    if ($null -ne $previousCpu) {
        $elapsed = ($now - $previousTime).TotalSeconds
        if ($elapsed -gt 0) {
            $cpuPercent = [math]::Round(100 * ($cpuSeconds - $previousCpu) / $elapsed, 1)
        }
    }

    $gpuSharedMiB = $null
    $gpuDedicatedMiB = $null
    try {
        $paths = @(Get-Counter -ListSet 'GPU Process Memory' -ErrorAction Stop |
            Select-Object -ExpandProperty PathsWithInstances |
            Where-Object { $_ -match "pid_${ProcessId}_" -and $_ -match '\\(Shared|Dedicated) Usage$' })
        if ($paths.Count -gt 0) {
            $gpuCounters = (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples
            $shared = @($gpuCounters | Where-Object { $_.Path -match '\\Shared Usage$' } |
                Measure-Object CookedValue -Sum)[0].Sum
            $dedicated = @($gpuCounters | Where-Object { $_.Path -match '\\Dedicated Usage$' } |
                Measure-Object CookedValue -Sum)[0].Sum
            $gpuSharedMiB = [math]::Round($shared / 1MB, 1)
            $gpuDedicatedMiB = [math]::Round($dedicated / 1MB, 1)
        }
    } catch {
        # GPU 计数器并非所有 Windows 设备都可用。
    }

    $samples.Add([pscustomobject]@{
        Time = $now.ToString('o')
        ProcessId = $ProcessId
        WorkingMiB = [math]::Round($process.WorkingSet64 / 1MB, 1)
        PrivateMiB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
        CpuPercentOneCore = $cpuPercent
        GpuSharedMiB = $gpuSharedMiB
        GpuDedicatedMiB = $gpuDedicatedMiB
    })
    $previousCpu = $cpuSeconds
    $previousTime = $now
    Start-Sleep -Seconds $IntervalSeconds
}

$samples | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
[pscustomobject]@{
    OutputPath = $OutputPath
    Samples = $samples.Count
    PeakWorkingMiB = ($samples | Measure-Object WorkingMiB -Maximum).Maximum
    PeakPrivateMiB = ($samples | Measure-Object PrivateMiB -Maximum).Maximum
    ProcessStillRunning = [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}
