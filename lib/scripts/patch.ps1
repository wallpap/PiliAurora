[CmdletBinding()]
param(
    [ValidateSet("", "android", "windows")]
    [string]$platform = "",
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"

$IsWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

$Workspace = if ($env:GITHUB_WORKSPACE) {
    $env:GITHUB_WORKSPACE
} else {
    Join-Path $PSScriptRoot "../.."
}
$Workspace = (Resolve-Path $Workspace).Path

function Resolve-FlutterRoot {
    if ($env:FLUTTER_ROOT -and (Test-Path $env:FLUTTER_ROOT)) {
        return (Resolve-Path $env:FLUTTER_ROOT).Path
    }

    $localProperties = Join-Path $Workspace "android/local.properties"
    if (Test-Path $localProperties) {
        $flutterLine = Get-Content $localProperties |
            Where-Object { $_ -match '^\s*flutter\.sdk=(.*)$' } |
            Select-Object -First 1
        if ($flutterLine -and $flutterLine -match '^\s*flutter\.sdk=(.*)$') {
            $candidate = $Matches[1].Trim().Replace('\\', '\')
            if (Test-Path $candidate) {
                return (Resolve-Path $candidate).Path
            }
        }
    }

    $projectFvmrc = Join-Path $Workspace ".fvmrc"
    $globalFvmrc = if ($env:APPDATA) {
        Join-Path $env:APPDATA "fvm/.fvmrc"
    } else {
        Join-Path $HOME ".fvmrc"
    }
    if (Test-Path $projectFvmrc -and Test-Path $globalFvmrc) {
        $version = (Get-Content $projectFvmrc -Raw | ConvertFrom-Json).flutter
        $cachePath = (Get-Content $globalFvmrc -Raw | ConvertFrom-Json).cachePath
        $candidate = Join-Path $cachePath "versions/$version"
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        return (Resolve-Path (Join-Path (Split-Path $flutterCommand.Source -Parent) "..")).Path
    }

    throw "Flutter SDK not found. Set FLUTTER_ROOT or install the version in .fvmrc."
}

function Apply-Patch([string]$PatchPath, [switch]$Reverse) {
    git apply --reverse --check --quiet $PatchPath 2>$null
    $applied = $LASTEXITCODE -eq 0
    if ($applied -and -not $Reverse) {
        Write-Verbose "$PatchPath already applied"
        return
    }

    if (-not $applied) {
        git apply --check --quiet $PatchPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Patch does not apply cleanly: $PatchPath"
        }
        if ($Reverse) { return }
    }

    [string[]]$options = if ($Reverse) { @("--reverse") } else { @() }
    git apply @options $PatchPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update patch: $PatchPath"
    }
    $script:PatchChanges++
    Write-Verbose "$PatchPath $(if ($Reverse) { 'removed' } else { 'applied' })"
}

function Resolve-PackageRoot([string]$Name) {
    $configPath = Join-Path $Workspace ".dart_tool/package_config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Package configuration missing. Run flutter pub get first."
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $package = $config.packages | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $package) { throw "Package not resolved: $Name" }
    $root = [Uri]::new([Uri]::new($configPath), $package.rootUri).LocalPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Resolved package directory missing: $root"
    }
    return (Resolve-Path -LiteralPath $root).Path
}

$FlutterRoot = Resolve-FlutterRoot
$FlutterExecutable = Join-Path $FlutterRoot "bin/flutter"
if ($IsWindowsPlatform -and (Test-Path "$FlutterExecutable.bat")) {
    $FlutterExecutable = "$FlutterExecutable.bat"
}

if (-not (Test-Path $FlutterExecutable)) {
    throw "Flutter executable not found under $FlutterRoot"
}

# set `gestureSettings`
$BottomSheetAndroidPatch = "lib/scripts/bottom_sheet_android.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1662
# handle bottom scroll event
$ScrollViewPatch = "lib/scripts/scroll_view.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2106
# use `TouchGestureRecognizer` on all platforms
$TextSelectionPatch = "lib/scripts/text_selection.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1947
$NavigatorPatch = "lib/scripts/navigator.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2107
$ImageAnimPatch = "lib/scripts/image_anim.patch"

# remove `_scheduleRebuild`
$LayoutBuilderPatch = "lib/scripts/layout_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2308
$NavigationDrawerPatch = "lib/scripts/navigation_drawer.patch"

# apply text color to icon color
$PopupMenuPatch = "lib/scripts/popup_menu.patch"

# remove `Hero` effect
$FABPatch = "lib/scripts/fab.patch"

# https://github.com/flutter/flutter/issues/139890
# https://github.com/flutter/flutter/issues/174689
# separator support
# clamp handle offset
# widgetspan selection support
# clear selection when tapping outside
# free selection if there is only one text
# clamp dragging selection behavior on Android
# show selection menu if secondary tap position is in text region on desktop
$SelectableRegionPatch = "lib/scripts/selectable_region.patch"

# https://github.com/flutter/flutter/issues/132047
# https://github.com/flutter/flutter/issues/174689
$EditableTextPatch = "lib/scripts/editable_text.patch"

# set `selectAllOnFocus` to `false` by default
$TextFieldPatch = "lib/scripts/text_field.patch"

# notify `userScrollDirection` only if position is actually changing
$ScrollPositionPatch = "lib/scripts/scroll_position.patch"

# expose `_shouldIgnorePointer`
$ScrollablePatch = "lib/scripts/scrollable.patch"

# expose
$ScaffoldPatch = "lib/scripts/scaffold.patch"

# fix nested scrollable gesture
# custom `HorizontalDragGestureRecognizer` support
$ScrollableGesturePatch = "lib/scripts/scrollable_gesture.patch"

# expose
$DraggableScrollableSheetPatch = "lib/scripts/draggable_scrollable_sheet.patch"

# expose
$TextPatch = "lib/scripts/text.patch"

# expose
$TextPainterPatch = "lib/scripts/text_painter.patch"

$SliverPatch = "lib/scripts/sliver.patch"

$RefreshIndicatorPatch = "lib/scripts/refresh_indicator.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/124078
# https://github.com/flutter/flutter/pull/183261
$NullSafetySelectableRegionPatch = "lib/scripts/null_safety_for_selectable_region.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/90223
$ModalBarrierPatch = "lib/scripts/modal_barrier.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/182466
$MouseCursorPatch = "lib/scripts/mouse_cursor.patch"

Set-Location $Workspace
if (-not $SkipPubGet) {
    $pubOutput = & $FlutterExecutable pub get --enforce-lockfile 2>&1
    if ($LASTEXITCODE -ne 0) {
        $pubOutput | ForEach-Object { Write-Host $_ }
        throw "flutter pub get failed with exit code $LASTEXITCODE"
    }
    $pubOutput | ForEach-Object { Write-Verbose $_ }
    Write-Host "依赖解析完成。"
}

Set-Location $FlutterRoot
$script:PatchChanges = 0
$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch)

$androidPatches = @($BottomSheetAndroidPatch, $ScrollViewPatch, $NavigatorPatch)
if ($platform -eq "android") {
    $patches += $androidPatches
}
elseif ($platform -eq "windows") {
    # 切换平台时恢复项目的 Android 专用补丁，保留 SDK 中的其它改动。
    foreach ($patch in $androidPatches) {
        Apply-Patch (Join-Path $Workspace $patch) -Reverse
    }
}

foreach ($patch in $patches) {
    Apply-Patch (Join-Path $Workspace $patch)
}

Write-Host "Flutter 补丁就绪（变更 $script:PatchChanges 项）。"
Set-Location $Workspace

$BottomSheetAndroidPatchMaterial = "lib/scripts/material/bottom_sheet_android.patch"

$ModalBarrierPatchMaterial = "lib/scripts/material/modal_barrier_material.patch"

$NavigationDrawerPatchMaterial = "lib/scripts/material/navigation_drawer.patch"

$PopupMenuPatchMaterial = "lib/scripts/material/popup_menu.patch"

$FABPatchMaterial = "lib/scripts/material/fab.patch"

$TextFieldPatchMaterial = "lib/scripts/material/text_field.patch"

$ScaffoldPatchMaterial = "lib/scripts/material/scaffold.patch"

$RefreshIndicatorPatchMaterial = "lib/scripts/material/refresh_indicator.patch"

$TabsPatchMaterial = "lib/scripts/material/tabs.patch"

$patches_material = @($ModalBarrierPatchMaterial, $NavigationDrawerPatchMaterial, $PopupMenuPatchMaterial,
                    $FABPatchMaterial, $TextFieldPatchMaterial, $ScaffoldPatchMaterial, $RefreshIndicatorPatchMaterial,
                    $TabsPatchMaterial)

switch ($platform.ToLower()) {
    "android" {
        $patches_material += $BottomSheetAndroidPatchMaterial
    }
    default {}
}

$MaterialUiRoot = Resolve-PackageRoot "material_ui"
Write-Verbose "material_ui dir: $MaterialUiRoot"
Set-Location $MaterialUiRoot
$script:PatchChanges = 0
if ($platform -eq "windows") {
    Apply-Patch (Join-Path $Workspace $BottomSheetAndroidPatchMaterial) -Reverse
}

foreach ($patch in $patches_material) {
    Apply-Patch (Join-Path $Workspace $patch)
}

Write-Host "material_ui 补丁就绪（变更 $script:PatchChanges 项）。"
Set-Location $Workspace
