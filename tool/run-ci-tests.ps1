[CmdletBinding()]
param(
    [ValidateSet("fvm", "path")]
    [string]$FlutterTool = "fvm"
)

$ErrorActionPreference = "Stop"
$Workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Workspace

# 默认 CI 保留关键行为回归；完整覆盖通过 fvm flutter test 按需运行。
$ciTests = @(
    # 架构与账号、数据安全
    "test/architecture/dependency_policy_test.dart",
    "test/architecture/dependency_rules_test.dart",
    "test/services/messaging/messaging_test.dart",
    "test/services/messaging/sharing_test.dart",
    "test/services/messaging/protocol_test.dart",
    "test/services/diagnostics/redact_test.dart",
    "test/services/diagnostics/record_store_test.dart",
    "test/services/settings/settings_backup_test.dart",
    "test/services/settings/webdav_sync_test.dart",
    "test/services/download/download_service_test.dart",
    # 页面退出、音频归属与播放会话
    "test/common/widgets/image/image_lifecycle_test.dart",
    "test/common/widgets/image/cached_image_transition_test.dart",
    "test/common/widgets/image/image_resume_inflight_test.dart",
    "test/common/widgets/image/decode_budget_cancel_test.dart",
    "test/common/widgets/image/network_thumbnail_test.dart",
    "test/pages/home/controller_lifecycle_test.dart",
    "test/router/get_route_lifecycle_test.dart",
    "test/app/desktop_playback_launch_test.dart",
    "test/pages/video/playback_lifecycle_test.dart",
    "test/pages/video/pgc_sharing_test.dart",
    "test/pages/live_room/controller_test.dart",
    "test/services/audio_session_test.dart",
    "test/services/audio_handler_lifecycle_test.dart",
    "test/plugin/pl_player/playback/playback_session_test.dart",
    "test/plugin/pl_player/playback/player_architecture_acceptance_test.dart",
    "test/plugin/pl_player/playback/playback_operation_scheduler_test.dart",
    "test/plugin/pl_player/playback/playback_runtime_slot_test.dart",
    "test/plugin/pl_player/playback/native_media_clock_sampling_test.dart",
    "test/plugin/pl_player/playback/native_load_readiness_test.dart",
    "test/plugin/pl_player/playback/video_frame_timings_test.dart",
    "test/plugin/pl_player/playback/presentation_profile_test.dart",
    "test/plugin/pl_player/playback/shader_updates_test.dart",
    # 原生输出、首帧与切换
    "test/plugin/pl_player/android/preloaded_surface_test.dart",
    "test/plugin/pl_player/android/android_video_output_test.dart",
    "test/plugin/pl_player/android/android_video_frame_handoff_test.dart",
    "test/plugin/pl_player/android/android_decode_lifecycle_test.dart",
    "test/plugin/pl_player/video_output/video_output_resizer_test.dart",
    "test/plugin/pl_player/video_output/video_output_handoff_test.dart",
    # 弹幕生产链路与帧计划
    "test/pages/danmaku/controller_test.dart",
    "test/pages/danmaku/file_store_test.dart",
    "test/pages/danmaku/window_coordinator_test.dart",
    "test/pages/danmaku/window_screen_test.dart",
    "test/pages/danmaku/window_renderer_test.dart",
    "test/pages/danmaku/live_layer_test.dart",
    "test/pages/danmaku/frame_rate_ticker_test.dart",
    "test/pages/danmaku/frame_deadline_replay_test.dart",
    "test/pages/danmaku/frame_plan_identity_test.dart",
    "test/pages/danmaku/video_presentation_cadence_test.dart"
)

Write-Host "Running the CI test suite ($($ciTests.Count) paths)..."
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
