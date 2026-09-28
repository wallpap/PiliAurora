param(
    [ValidateSet("android", "windows")]
    [string]$Platform = "windows",
    [ValidateSet("debug", "profile", "release")]
    [string]$Mode = "debug",
    [switch]$SkipPatch
)

$ErrorActionPreference = "Stop"
$Workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Workspace

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
        [string[]]$Arguments
    )

    & $dart.Source @fvmEntryPoint @Arguments
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

Invoke-Fvm @("exec", "flutter", "pub", "get")

if (-not $SkipPatch) {
    $patchScript = Join-Path $Workspace "lib/scripts/patch.ps1"
    $selectedFlutterRoot = Resolve-FvmFlutterRoot
    $inheritedFlutterRoot = $env:FLUTTER_ROOT
    $inheritedPath = $env:PATH
    $env:FLUTTER_ROOT = $selectedFlutterRoot
    $env:PATH = "$(Join-Path $selectedFlutterRoot 'bin');$inheritedPath"
    try {
        & pwsh -NoProfile -File $patchScript $Platform
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

$target = if ($Platform -eq "android") { "apk" } else { "windows" }
Invoke-Fvm @("exec", "flutter", "build", $target, "--$Mode")
