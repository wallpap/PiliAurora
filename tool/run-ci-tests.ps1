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
    "test/app/startup_test.dart",
    "test/app/startup_failure_test.dart",
    "test/services/app_exit_test.dart",
    "test/services/audio_session_initialization_test.dart",
    "test/http/loading_state_test.dart",
    "test/http/api_response_test.dart",
    "test/http/relationship_response_test.dart",
    "test/http/fav_response_test.dart",
    "test/http/validate_response_test.dart",
    "test/http/video_feedback_results_test.dart",
    "test/http/video_interaction_results_test.dart",
    "test/http/video_query_results_test.dart",
    "test/http/video_media_results_test.dart",
    "test/http/video_reporting_results_test.dart",
    "test/pages/video/interaction_results_test.dart",
    "test/pages/video/pay_coins/pay_coins_test.dart",
    "test/pages/popular_series/controller_test.dart",
    "test/common/widgets/video_feedback_results_test.dart",
    "test/http/member_mutation_results_test.dart",
    "test/http/member_query_results_test.dart",
    "test/common/widgets/member_report_results_test.dart",
    "test/pages/video/member_results_test.dart",
    "test/http/login_account_results_test.dart",
    "test/pages/setting/logout_results_test.dart",
    "test/pages/fav/note_results_test.dart",
    "test/pages/fav/account_favorite_results_test.dart",
    "test/pages/pgc/pugv_favorite_results_test.dart",
    "test/pages/episode_panel/favorite_results_test.dart",
    "test/pages/subscription/detail_filter_test.dart",
    "test/pages/member_favorite/pagination_lifecycle_test.dart",
    "test/pages/search_panel/esports_fallback_test.dart",
    "test/pages/subscription/operation_results_test.dart",
    "test/http/pgc_response_test.dart",
    "test/http/pgc_follow_results_test.dart",
    "test/pages/pgc/follow_results_test.dart",
    "test/pages/pgc/operation_results_test.dart",
    "test/http/metadata_response_test.dart",
    "test/http/sponsor_block_response_test.dart",
    "test/http/user_response_test.dart",
    "test/http/community_response_test.dart",
    "test/http/reply_write_results_test.dart",
    "test/http/dynamics_response_test.dart",
    "test/http/dynamic_media_response_test.dart",
    "test/http/member_dynamics_response_test.dart",
    "test/pages/dynamics/",
    "test/pages/article/controller_results_test.dart",
    "test/pages/article/content_retry_test.dart",
    "test/http/live_response_test.dart",
    "test/pages/live/consumer_results_test.dart",
    "test/pages/live_room/send_results_test.dart",
    "test/pages/live_emote/controller_test.dart",
    "test/pages/community/operation_results_test.dart",
    "test/pages/community/reply_list_results_test.dart",
    "test/pages/community/reply_publish_results_test.dart",
    "test/pages/community/reply_search_results_test.dart",
    "test/pages/history/operation_results_test.dart",
    "test/pages/sponsor_block/operation_results_test.dart",
    "test/pages/sponsor_block/block_mixin_test.dart",
    "test/utils/sponsor_block_settings_test.dart",
    "test/pages/metadata/controller_test.dart",
    "test/pages/metadata/view_test.dart",
    "test/utils/gaia_validation_test.dart",
    "test/utils/background_sync_results_test.dart",
    "test/pages/fav/operation_results_test.dart",
    "test/pages/fav/management_results_test.dart",
    "test/http/retry_interceptor_test.dart",
    "test/grpc/request_test.dart",
    "test/http/login_test.dart",
    "test/http/search_response_test.dart",
    "test/http/download_response_test.dart",
    "test/utils/accounts/cookie_failure_test.dart",
    "test/utils/image_save_results_test.dart",
    "test/pages/login/request_lifecycle_test.dart",
    "test/services/messaging/messaging_test.dart",
    "test/services/messaging/sharing_test.dart",
    "test/services/messaging/protocol_test.dart",
    "test/services/messaging/preferences_test.dart",
    "test/services/account_providers_test.dart",
    "test/services/diagnostics/redact_test.dart",
    "test/services/diagnostics/record_store_test.dart",
    "test/services/diagnostics/diagnostics_test.dart",
    "test/services/diagnostics/report_handler_test.dart",
    "test/services/diagnostics/app_logger_test.dart",
    "test/services/diagnostics/player_logging_test.dart",
    "test/pages/about/diagnostics_page_test.dart",
    "test/services/settings/settings_backup_test.dart",
    "test/services/settings/webdav_sync_test.dart",
    "test/services/download/download_service_test.dart",
    "test/services/download/download_manager_test.dart",
    # 页面退出、音频归属与播放会话
    "test/common/widgets/image/image_lifecycle_test.dart",
    "test/common/widgets/image/cached_image_transition_test.dart",
    "test/common/widgets/image/image_resume_inflight_test.dart",
    "test/common/widgets/image/decode_budget_cancel_test.dart",
    "test/common/widgets/image/network_thumbnail_test.dart",
    "test/pages/home/controller_lifecycle_test.dart",
    "test/pages/search/controller_test.dart",
    "test/pages/scoped_search/controller_test.dart",
    "test/pages/space_setting/controller_test.dart",
    "test/pages/live_settings/controller_test.dart",
    "test/pages/member_feed/controller_test.dart",
    "test/pages/search_results/controller_test.dart",
    "test/pages/danmaku_block/controller_test.dart",
    "test/pages/blacklist/controller_test.dart",
    "test/pages/account_queries/provider_test.dart",
    "test/pages/follow_type/controller_test.dart",
    "test/pages/follow/controller_test.dart",
    "test/pages/live_follow/controller_test.dart",
    "test/common/widgets/feed_pagination_test.dart",
    "test/pages/rcmd/",
    "test/router/get_route_lifecycle_test.dart",
    "test/utils/app_release_test.dart",
    "test/utils/grid_test.dart",
    "test/utils/waterfall_test.dart",
    "test/pages/video/playback_lifecycle_test.dart",
    "test/pages/video/pgc_sharing_test.dart",
    "test/pages/video/reply/controller_test.dart",
    "test/pages/video/reply/timestamp_test.dart",
    "test/pages/video/reply_reply/level_filter_test.dart",
    "test/pages/video/reply_reply/lifecycle_test.dart",
    "test/utils/reply_filter_test.dart",
    "test/pages/setting/settings_navigation_test.dart",
    "test/pages/setting/decoder_test_test.dart",
    "test/pages/setting/decoder_test_process_test.dart",
    "test/pages/setting/decoder_test_dialog_test.dart",
    "test/pages/live_room/controller_test.dart",
    "test/services/live_stream/live_stream_test.dart",
    "test/services/audio_session_test.dart",
    "test/services/desktop_playback_windows_test.dart",
    "test/services/desktop_playback_layout_test.dart",
    "test/services/audio_handler_lifecycle_test.dart",
    "test/plugin/pl_player/playback/playback_session_test.dart",
    "test/plugin/pl_player/playback/playback_model_test.dart",
    "test/plugin/pl_player/fullscreen_system_ui_test.dart",
    "test/plugin/pl_player/playback/controller_recovery_test.dart",
    "test/plugin/pl_player/playback/audio_recovery_test.dart",
    "test/plugin/pl_player/playback/network_recovery_test.dart",
    "test/plugin/pl_player/playback/progress_projection_test.dart",
    "test/plugin/pl_player/player_loading_test.dart",
    "test/plugin/pl_player/playback/player_architecture_acceptance_test.dart",
    "test/plugin/pl_player/playback/playback_operation_scheduler_test.dart",
    "test/plugin/pl_player/playback/playback_runtime_slot_test.dart",
    "test/plugin/pl_player/playback/native_media_clock_sampling_test.dart",
    "test/plugin/pl_player/native_flag_test.dart",
    "test/plugin/pl_player/playback/native_load_readiness_test.dart",
    "test/plugin/pl_player/playback/native_shutdown_test.dart",
    "test/plugin/pl_player/playback/video_frame_timings_test.dart",
    "test/plugin/pl_player/playback/presentation_profile_test.dart",
    "test/plugin/pl_player/playback/shader_updates_test.dart",
    # 跨平台输出、首帧与切换
    "test/plugin/pl_player/video_output/video_output_resizer_test.dart",
    "test/plugin/pl_player/video_output/video_output_handoff_test.dart",
    # 弹幕生产链路与帧计划
    "tool/experiments/danmaku/density_metrics_test.dart",
    "test/pages/danmaku/priority_test.dart",
    "test/pages/danmaku/cache_test.dart",
    "test/pages/danmaku/merge_test.dart",
    "test/pages/danmaku/arrangement_test.dart",
    "test/pages/danmaku/timeline_window_test.dart",
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

# 原生 Windows 窗口时序依赖 dart:io 的主机平台，Linux 上不模拟该分支。
if ($IsWindows) {
    $ciTests += @(
        "test/app/desktop_theme_test.dart",
        "test/app/desktop_title_bar_test.dart",
        "test/app/platform_setup_test.dart",
        "test/utils/desktop_window_background_test.dart",
        "test/app/desktop_playback_launch_test.dart",
        "test/plugin/pl_player/fullscreen_transition_test.dart",
        "test/plugin/pl_player/fullscreen_model_test.dart"
    )
}
elseif ($IsLinux) {
    # Android 平台通道使用模拟输入，在发布所用 Linux 主机运行。
    $ciTests += @(
        "test/plugin/pl_player/android/preloaded_surface_test.dart",
        "test/plugin/pl_player/android/android_video_output_test.dart",
        "test/plugin/pl_player/android/android_video_frame_handoff_test.dart",
        "test/plugin/pl_player/android/android_decode_lifecycle_test.dart"
    )
}

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
