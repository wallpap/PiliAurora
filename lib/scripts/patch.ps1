param(
    [string]$platform = ""
)

$ErrorActionPreference = "Stop"

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

function Apply-Patch([string]$PatchPath) {
    git apply --check --quiet $PatchPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        git apply $PatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply patch: $PatchPath"
        }
        Write-Host "$PatchPath applied"
        return
    }

    git apply --reverse --check --quiet $PatchPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$PatchPath already applied"
        return
    }

    throw "Patch does not apply cleanly: $PatchPath"
}

$FlutterRoot = Resolve-FlutterRoot
$FlutterExecutable = Join-Path $FlutterRoot "bin/flutter"
if (Test-Path "$FlutterExecutable.bat") {
    $FlutterExecutable = "$FlutterExecutable.bat"
}

if (-not (Test-Path $FlutterExecutable)) {
    throw "Flutter executable not found under $FlutterRoot"
}

# TODO: remove
# https://github.com/flutter/flutter/issues/182281
$NewOverScrollIndicator = "362b1de29974ffc1ed6faa826e1df870d7bec75f";

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

Set-Location $FlutterRoot

$picks   = @()
$reverts = @()
$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch)

switch ($platform.ToLower()) {
    "android" {
        $patches += $BottomSheetAndroidPatch
        $patches += $ScrollViewPatch
        $patches += $NavigatorPatch

        git reset --hard HEAD
    }
    "windows" {
        git reset --hard HEAD
    }
    default {}
}

foreach ($pick in $picks) {
    git stash
    git cherry-pick $pick --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$pick picked"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($revert in $reverts) {
    git stash
    git revert $revert --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$revert reverted"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($patch in $patches) {
    Apply-Patch (Join-Path $Workspace $patch)
}

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

$PubCacheDir = $env:PUB_CACHE
if (-not $PubCacheDir) {
    $PubCacheDir = if ($IsWindows) {
        Join-Path $env:LOCALAPPDATA "Pub/Cache"
    } else {
        Join-Path $HOME ".pub-cache"
    }
}

switch ($platform.ToLower()) {
    "android" {
        $patches_material += $BottomSheetAndroidPatchMaterial
    }
    default {}
}

$PubCacheDir = (Resolve-Path $PubCacheDir).Path
$HostedPubDir = Join-Path $PubCacheDir "hosted/pub.dev"

try {
    $MaterialUiDir = Get-ChildItem $HostedPubDir -Directory |
        Where-Object { $_.Name -like "material_ui-*" } |
        Sort-Object LastWriteTime |
        Select-Object -Last 1

    if ($MaterialUiDir) {
        Remove-Item -Path $MaterialUiDir.FullName -Recurse -Force
    }
} catch {
}

& $FlutterExecutable pub get
if ($LASTEXITCODE -ne 0) {
    throw "flutter pub get failed with exit code $LASTEXITCODE"
}

$MaterialUiDir = Get-ChildItem $HostedPubDir -Directory |
    Where-Object { $_.Name -like "material_ui-*" } |
    Sort-Object LastWriteTime |
    Select-Object -Last 1

if (-not $MaterialUiDir) {
    throw "material_ui package not found in pub cache"
}

Write-Host "material_ui dir: $($MaterialUiDir.FullName)"

Get-ChildItem -Path (Join-Path $Workspace "lib/scripts/material") -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $MaterialUiDir.FullName

foreach ($patch in $patches_material) {
    Apply-Patch (Join-Path $Workspace $patch)
}

$patches_cupertino = @()

switch ($platform.ToLower()) {
    "android" {
    }
    "windows" {
    }
    default {}
}

if ($patches_cupertino.Count -gt 0) {
    $CupertinoUiDir = Get-ChildItem $HostedPubDir -Directory |
        Where-Object { $_.Name -like "cupertino_ui-*" } |
        Sort-Object LastWriteTime |
        Select-Object -Last 1

    if (-not $CupertinoUiDir) {
        throw "cupertino_ui package not found in pub cache"
    }

    Write-Host "cupertino_ui dir: $($CupertinoUiDir.FullName)"

    $cupertinoPatchDir = Join-Path $Workspace "lib/scripts/cupertino"
    if (Test-Path $cupertinoPatchDir) {
        Get-ChildItem -Path $cupertinoPatchDir -Filter *.patch | ForEach-Object {
            (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" |
                Set-Content -NoNewline $_.FullName
        }
    }

    Set-Location $CupertinoUiDir.FullName

    foreach ($patch in $patches_cupertino) {
        Apply-Patch (Join-Path $Workspace $patch)
    }
}
