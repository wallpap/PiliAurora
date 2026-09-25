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

$fvm = Get-Command fvm -ErrorAction SilentlyContinue
if (-not $fvm) {
    throw "FVM is required. Install FVM and the Flutter version declared in .fvmrc."
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

& fvm flutter pub get
if ($LASTEXITCODE -ne 0) {
    throw "fvm flutter pub get failed with exit code $LASTEXITCODE"
}

if (-not $SkipPatch) {
    $patchScript = Join-Path $Workspace "lib/scripts/patch.ps1"
    & pwsh -NoProfile -File $patchScript $Platform
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter patch step failed with exit code $LASTEXITCODE"
    }
}

$target = if ($Platform -eq "android") { "apk" } else { "windows" }
& fvm flutter build $target "--$Mode"
if ($LASTEXITCODE -ne 0) {
    throw "Flutter build failed with exit code $LASTEXITCODE"
}
