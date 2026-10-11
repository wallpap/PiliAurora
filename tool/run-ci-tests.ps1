[CmdletBinding()]
param(
    [ValidateSet("fvm", "path")]
    [string]$FlutterTool = "fvm"
)

$ErrorActionPreference = "Stop"
$Workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Workspace

$ciTests = @(
    "test/architecture/dependency_policy_test.dart",
    "test/architecture/internal_dependencies_test.dart",
    "test/common/widgets/font_awesome_icons_test.dart",
    "test/common/widgets/debounced_state_test.dart",
    "test/common/widgets/image/image_lifecycle_test.dart",
    "test/utils/random_id_test.dart",
    "test/utils/rate_limiter_test.dart",
    "test/services/diagnostics/app_logger_test.dart",
    "test/services/diagnostics/catcher_logging_test.dart",
    "test/services/settings/webdav_client_test.dart",
    "test/architecture/dependency_rules_test.dart",
    "test/architecture/release_workflow_test.dart",
    "test/pages/common/common_controller_test.dart",
    "test/services/settings/settings_backup_test.dart",
    "test/services/settings/webdav_sync_test.dart",
    "test/services/diagnostics/diagnostics_test.dart",
    "test/services/diagnostics/redact_test.dart",
    "test/services/diagnostics/http_diagnostics_test.dart",
    "test/services/diagnostics/record_store_test.dart",
    "test/services/diagnostics/player_diagnostics_test.dart",
    "test/services/diagnostics/process_metrics_test.dart",
    "test/pages/about/diagnostics_page_test.dart",
    "test/plugin/pl_player/video_output/video_output_resizer_test.dart",
    "test/plugin/pl_player/android/android_video_output_test.dart",
    "test/plugin/pl_player/video_output/video_output_size_test.dart",
    "test/plugin/pl_player/android/android_decode_recovery_test.dart",
    "test/plugin/pl_player/android/android_decode_lifecycle_test.dart",
    "test/plugin/pl_player/hardware_video_configuration_test.dart",
    "test/plugin/pl_player/android/android_fixed_surface_size_test.dart",
    "test/plugin/pl_player/playback/playback_timing_contract_test.dart",
    "test/pages/setting/decoder_test_dialog_test.dart"
)

Write-Host "Running the CI test suite ($($ciTests.Count) files)..."
if ($FlutterTool -eq "fvm") {
    & fvm flutter test --no-pub @ciTests
    $command = "fvm flutter test --no-pub"
}
else {
    & flutter test --no-pub @ciTests
    $command = "flutter test --no-pub"
}

if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $command"
}

Write-Host "Local CI tests completed successfully."
