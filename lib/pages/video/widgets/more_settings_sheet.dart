import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'dart:math' show min, max;

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_select_field.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_info_dialog.dart';
import 'package:pili_aurora/services/shutdown_timer_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/connectivity_utils.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/video_utils.dart';

Future<void> showVideoMoreSettings(
  BuildContext context, {
  required VideoDetailController controller,
  required CommonIntroController introController,
  VoidCallback? onSubtitleSettings,
  VoidCallback? onLoadSubtitle,
  VoidCallback? onSaveSubtitle,
  VoidCallback? onDanmakuList,
}) async {
  final player = controller.plPlayerController;
  final theme = player.darkVideoPage ? ThemeUtils.darkTheme : Theme.of(context);
  final panel = Theme(
    data: theme,
    child: VideoMoreSettingsSheet(
      controller: controller,
      introController: introController,
      sourceContext: context,
      onSubtitleSettings: onSubtitleSettings,
      onLoadSubtitle: onLoadSubtitle,
      onSaveSubtitle: onSaveSubtitle,
      onDanmakuList: onDanmakuList,
    ),
  );
  player.setControlsMenuOpen(true);
  try {
    if (PlatformUtils.isDesktop) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭更多设置',
        barrierColor: Colors.black26,
        pageBuilder: (context, _, _) => LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Offset.zero & constraints.biggest;
            final anchorContext =
                controller.moreSettingsAnchorKey.currentContext ??
                controller.videoPlayerKey.currentContext;
            final anchor = anchorContext?.findRenderObject();
            final overlay = Navigator.of(context).overlay!.context
                .findRenderObject();
            final rect =
                anchor is RenderBox && anchor.hasSize && !anchor.size.isEmpty
                ? MatrixUtils.transformRect(
                    anchor.getTransformTo(overlay),
                    Offset.zero & anchor.size,
                  ).intersect(viewport)
                : viewport;
            final top = rect.top + (rect.height > 260 ? 44 : 8);
            final bottom = rect.bottom - (rect.height > 360 ? 52 : 8);
            return Stack(
              children: [
                Positioned(
                  top: top,
                  left: max(rect.left + 8, rect.right - 350),
                  width: min(340, max(0, rect.width - 16)),
                  height: max(0, bottom - top),
                  child: panel,
                ),
              ],
            );
          },
        ),
      );
    } else {
      await PageUtils.showVideoBottomSheet(
        context,
        maxWidth: 512,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: panel,
        ),
      );
    }
  } finally {
    player.setControlsMenuOpen(false);
  }
}

class VideoMoreSettingsSheet extends StatefulWidget {
  const VideoMoreSettingsSheet({
    super.key,
    required this.controller,
    required this.introController,
    required this.sourceContext,
    this.onSubtitleSettings,
    this.onLoadSubtitle,
    this.onSaveSubtitle,
    this.onDanmakuList,
  });

  final VideoDetailController controller;
  final CommonIntroController introController;
  final BuildContext sourceContext;
  final VoidCallback? onSubtitleSettings;
  final VoidCallback? onLoadSubtitle;
  final VoidCallback? onSaveSubtitle;
  final VoidCallback? onDanmakuList;

  @override
  State<VideoMoreSettingsSheet> createState() => _VideoMoreSettingsSheetState();
}

class _VideoMoreSettingsSheetState extends State<VideoMoreSettingsSheet> {
  final _scrollController = ScrollController();
  bool _advanced = false;
  VideoDetailController get controller => widget.controller;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _run(VoidCallback action) {
    Navigator.of(context).pop();
    if (widget.sourceContext.mounted) action();
  }

  Widget _switch(
    IconData icon,
    String label,
    bool value,
    ValueChanged<bool>? onChanged,
  ) => SwitchListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    secondary: Icon(icon, size: 20),
    title: Text(label, style: const TextStyle(fontSize: 13)),
    value: value,
    onChanged: onChanged,
    visualDensity: VisualDensity.compact,
  );

  Widget _select<T>(
    IconData icon,
    String label, {
    required T? value,
    required String selectedLabel,
    required List<(T, String)> options,
    required ValueChanged<T> onSelected,
    Widget? selectedWidget,
    String? hint,
    bool enabled = true,
  }) {
    final colors = ColorScheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 8),
          AppSelectField<T>(
            value: value,
            label: label,
            selectedLabel: selectedLabel,
            options: options,
            onSelected: onSelected,
            enabled: enabled,
            tooltip: hint ?? '$label：$selectedLabel',
            selectedWidget: selectedWidget,
          ),
        ],
      ),
    );
  }

  Widget _action(
    IconData icon,
    String label,
    VoidCallback? action, {
    bool navigate = false,
  }) => ListTile(
    dense: true,
    minTileHeight: 42,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: Icon(icon, size: 20),
    title: Text(label, style: const TextStyle(fontSize: 13)),
    trailing: navigate ? const Icon(Icons.chevron_right, size: 18) : null,
    enabled: action != null,
    onTap: action == null ? null : () => _run(action),
  );

  Widget _timer() => ShutdownPanel(
    buildCountdownText: (text) => Text(text ?? '关闭'),
    builder: (context, countdown, onCountdown, refresh) {
      final service = shutdownTimerService;
      final minutes = service.isActive || service.isWaiting
          ? service.durationInMinutes
          : 0;
      final choices = {0, 15, 30, 45, 60, if (minutes > 0) minutes}.toList()
        ..sort();
      return _select<int>(
        Icons.hourglass_top_outlined,
        '定时关闭',
        value: minutes,
        selectedLabel: minutes == 0 ? '关闭' : '$minutes 分钟',
        selectedWidget: countdown,
        options: [
          for (final n in choices) (n, n == 0 ? '关闭' : '$n 分钟'),
          (-1, '自定义与结束方式…'),
        ],
        onSelected: (value) {
          if (value == -1) {
            _run(
              () => service.showScheduleExitDialog(
                widget.sourceContext,
                isFullScreen: controller.plPlayerController.isFullScreen.value,
              ),
            );
          } else {
            service.startShutdownTimer(value);
            onCountdown();
            refresh(() {});
          }
        },
      );
    },
  );

  Widget _contentActions() {
    final actions = <(IconData, String, VoidCallback)>[
      (Icons.watch_later_outlined, '稍后再看', widget.introController.viewLater),
      if (controller.epId == null)
        (
          Icons.note_alt_outlined,
          '查看笔记',
          () => controller.showNoteList(widget.sourceContext),
        ),
      if (!controller.isFileSource)
        (
          Icons.download_outlined,
          '离线缓存',
          () => controller.onDownload(widget.sourceContext),
        ),
      if (!controller.isFileSource &&
          controller.isUgc &&
          (!PlatformUtils.isDesktop ||
              controller.plPlayerController.isFullScreen.value ||
              controller.plPlayerController.isDesktopPip))
        (Icons.headphones_outlined, '听音频', controller.toAudioPage),
      if (controller.cover.value.isNotEmpty)
        (
          Icons.image_outlined,
          '保存封面',
          () => ImageUtils.downloadImg([controller.cover.value]),
        ),
      if (!controller.isFileSource)
        (
          Icons.flag_outlined,
          '举报',
          () {
            if (Accounts.main.isLogin) {
              PageUtils.reportVideo(controller.aid);
            } else {
              SmartDialog.showToast('账号未登录');
            }
          },
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Text(
            '视频操作',
            style: TextStyle(
              fontSize: 11,
              color: ColorScheme.of(context).onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            children: [
              for (final (icon, label, action) in actions)
                FractionallySizedBox(
                  widthFactor: .5,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: ColorScheme.of(context).onSurface,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _run(action),
                    child: Row(
                      children: [
                        Icon(icon, size: 18),
                        const SizedBox(width: 9),
                        Flexible(child: Text(label)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _advancedSettings() {
    final player = controller.plPlayerController;
    final data = !controller.isFileSource && controller.videoState.value
        ? controller.data
        : null;
    final audio = data?.dash?.audio ?? [];
    final codecs =
        data?.supportFormats
            ?.firstWhereOrNull(
              (format) =>
                  format.quality == controller.currentVideoQa.value?.code,
            )
            ?.codecs ??
        <String>[];
    final formats = VideoDecodeFormatType.values
        .where(
          (format) => codecs.any((codec) => format.codes.any(codec.startsWith)),
        )
        .toList();
    final nativePlayer = player.videoPlayerController;
    return [
      _action(
        Icons.subtitles_outlined,
        '字幕设置',
        widget.onSubtitleSettings,
        navigate: true,
      ),
      if (!controller.isFileSource) ...[
        _select<AudioQuality>(
          Icons.album_outlined,
          '音质',
          value: controller.currentAudioQa,
          selectedLabel:
              controller.currentAudioQa?.desc ??
              (data == null ? '等待播放源' : '当前源不支持'),
          options: [
            for (final item in audio)
              (AudioQuality.fromCode(item.id), item.quality),
          ],
          enabled: controller.currentAudioQa != null && audio.isNotEmpty,
          onSelected: (value) async {
            if (value == controller.currentAudioQa &&
                controller.playbackSourceMatchesSelection &&
                player.currentPlaybackSnapshot.phase == PlaybackPhase.ready) {
              return;
            }
            if (!identical(controller.data, data)) return;
            final sourceData = data;
            final ownsPlayback = controller.playbackOwner.guard();
            final result = await controller.updatePlayer(audioQuality: value);
            if (!mounted ||
                !ownsPlayback() ||
                controller.isClosed ||
                !identical(controller.data, sourceData) ||
                result.outcome != LoadOutcome.ready) {
              return;
            }
            setState(() {});
            if (!player.tempPlayerConf) {
              final network = await ConnectivityUtils.queryWiFi();
              if (!mounted ||
                  controller.isClosed ||
                  !ownsPlayback() ||
                  !identical(controller.data, sourceData) ||
                  player.tempPlayerConf ||
                  controller.currentAudioQa != value) {
                return;
              }
              if (network is! Success<bool>) {
                SmartDialog.showToast('音质已应用，网络类型未知，未保存默认值');
                return;
              }
              try {
                await GStorage.setting.put(
                  network.response
                      ? SettingBoxKey.defaultAudioQa
                      : SettingBoxKey.defaultAudioQaCellular,
                  value.code,
                );
              } catch (error, stackTrace) {
                logger.w(
                  '保存默认音质失败',
                  error: error.runtimeType,
                  stackTrace: stackTrace,
                );
                if (mounted && !controller.isClosed) {
                  SmartDialog.showToast('音质已应用，默认值保存失败，请重试');
                }
              }
            }
          },
        ),
        _select<VideoDecodeFormatType>(
          Icons.av_timer_outlined,
          '编码格式',
          value: formats.isEmpty ? null : controller.currentDecodeFormats,
          selectedLabel: formats.isEmpty
              ? (data == null ? '等待播放源' : '当前源不支持')
              : controller.currentDecodeFormats.description,
          options: [for (final format in formats) (format, format.description)],
          enabled: formats.isNotEmpty,
          onSelected: (value) async {
            if (controller.currentDecodeFormats == value &&
                controller.playbackSourceMatchesSelection &&
                player.currentPlaybackSnapshot.phase == PlaybackPhase.ready) {
              return;
            }
            if (!identical(controller.data, data)) return;
            final result = await controller.updatePlayer(codec: value);
            if (mounted && result.outcome == LoadOutcome.ready) {
              setState(() {});
            }
          },
        ),
        _select<CDNService>(
          Icons.cloud_outlined,
          'CDN',
          value: VideoUtils.cdnService,
          selectedLabel: VideoUtils.cdnService.name,
          hint: VideoUtils.cdnService.desc,
          options: [
            for (final service in CDNService.values) (service, service.desc),
          ],
          onSelected: (value) {
            if (VideoUtils.cdnService == value) return;
            VideoUtils.cdnService = value;
            GStorage.setting.put(SettingBoxKey.CDNService, value.name);
            if (controller.videoState.value) {
              controller.queryVideoUrl(fromReset: true);
            }
            setState(() {});
          },
        ),
      ],
      _select<SuperResolutionType>(
        Icons.stay_current_landscape_outlined,
        '超分辨率',
        value: player.superResolutionType.value,
        selectedLabel: player.superResolutionType.value.label,
        options: [
          for (final type in SuperResolutionType.values) (type, type.label),
        ],
        enabled:
            player.superResolutionAvailability ==
            SuperResolutionEligibility.allowed,
        hint:
            player.superResolutionAvailability ==
                SuperResolutionEligibility.allowed
            ? null
            : '等待可用的视频和屏幕尺寸，或当前分辨率过高',
        onSelected: player.setShader,
      ),
      _switch(
        Icons.flip,
        '左右翻转',
        player.flipX.value,
        (value) => player.flipX.value = value,
      ),
      _switch(
        Icons.flip_camera_android_outlined,
        '上下翻转',
        player.flipY.value,
        (value) => player.flipY.value = value,
      ),
      _action(Icons.file_open_outlined, '加载本地字幕', widget.onLoadSubtitle),
      if (!controller.isFileSource)
        _action(
          Icons.download_outlined,
          '保存字幕',
          controller.subtitles.isEmpty ? null : widget.onSaveSubtitle,
        ),
      _action(Icons.list_alt_outlined, '弹幕列表', widget.onDanmakuList),
      if (!controller.isFileSource)
        _action(
          Icons.refresh_outlined,
          '重载视频',
          () => controller.queryVideoUrl(fromReset: true),
        ),
      _action(
        Icons.info_outline,
        '播放信息',
        nativePlayer == null
            ? null
            : () => showDialog<void>(
                context: widget.sourceContext,
                builder: (_) => PlayerInfoDialog(
                  state: nativePlayer.state,
                  hwdec: nativePlayer.getProperty('hwdec-current'),
                  volume: nativePlayer.getProperty('volume'),
                ),
              ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final player = controller.plPlayerController;
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    return Material(
      color: colors.surface,
      borderRadius: isPortrait
          ? const BorderRadius.vertical(top: Radius.circular(12))
          : BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '更多设置',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: PlatformUtils.isDesktop,
                child: Padding(
                  // 始终保留滚动条宽度，展开高级设置时控件列保持原位。
                  padding: const EdgeInsets.only(right: 8),
                  child: Obx(() {
                    final fileSource = player.currentFileSource;
                    final audioAvailable = controller.isFileSource
                        ? fileSource != null && !fileSource.isMp4
                        : controller.audioUrl?.isNotEmpty == true;
                    return ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        if (PlatformUtils.isDesktop)
                          _switch(
                            Icons.pause_circle_outline,
                            '最小化时暂停',
                            player.pauseOnMinimize.value,
                            (value) {
                              player.pauseOnMinimize.value = value;
                              if (!player.tempPlayerConf) {
                                GStorage.setting.put(
                                  SettingBoxKey.pauseOnMinimize,
                                  value,
                                );
                                if (Get.isRegistered<MainController>()) {
                                  Get.find<MainController>().pauseOnMinimize =
                                      value;
                                }
                              }
                            },
                          ),
                        if (PlatformUtils.isMobile)
                          _switch(
                            Icons.play_circle_outline,
                            '后台播放',
                            player.continuePlayInBackground.value,
                            (_) => player.setContinuePlayInBackground(),
                          ),
                        _switch(
                          Icons.headphones_outlined,
                          '仅播放音频',
                          player.onlyPlayAudio.value,
                          audioAvailable
                              ? (value) => unawaited(player.setOnlyAudio(value))
                              : null,
                        ),
                        if (Platform.isAndroid)
                          _switch(
                            Icons.picture_in_picture_outlined,
                            '自动画中画',
                            player.autoPipEnabled.value,
                            player.setAutoPiP,
                          ),
                        const Divider(height: 12),
                        _timer(),
                        _select<PlayRepeat>(
                          Icons.repeat,
                          '播放顺序',
                          value: player.playRepeat,
                          selectedLabel: player.playRepeat.label,
                          options: [
                            for (final repeat in PlayRepeat.values)
                              (repeat, repeat.label),
                          ],
                          onSelected: (value) {
                            player.setPlayRepeat(value);
                            setState(() {});
                          },
                        ),
                        _contentActions(),
                        const Divider(height: 12),
                        ListTile(
                          dense: true,
                          minTileHeight: 44,
                          leading: const Icon(Icons.tune, size: 20),
                          title: const Text(
                            '高级设置',
                            style: TextStyle(fontSize: 13),
                          ),
                          trailing: Icon(
                            _advanced ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                          ),
                          onTap: () => setState(() => _advanced = !_advanced),
                        ),
                        if (_advanced) ..._advancedSettings(),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
