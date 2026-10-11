import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:pili_aurora/common/widgets/marquee.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/widgets/live_stream_panel.dart';
import 'package:pili_aurora/pages/setting/models/play_settings.dart'
    show showPlayerVolumeDialog;
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/desktop_playback_menu.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/desktop_window_controls.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/common_btn.dart';
import 'package:pili_aurora/services/shutdown_timer_service.dart'
    show shutdownTimerService;
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/extension/context_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class LiveHeaderControl extends StatefulWidget {
  const LiveHeaderControl({
    super.key,
    required this.title,
    required this.upName,
    required this.plPlayerController,
    required this.onSendDanmaku,
    required this.onPlayAudio,
    required this.isPortrait,
    required this.liveController,
    required this.onlineWidget,
  });

  final String? title;
  final String? upName;
  final PlPlayerController plPlayerController;
  final VoidCallback onSendDanmaku;
  final VoidCallback onPlayAudio;
  final bool isPortrait;
  final LiveRoomController liveController;
  final Widget onlineWidget;

  @override
  State<LiveHeaderControl> createState() => _LiveHeaderControlState();
}

class _LiveHeaderControlState extends State<LiveHeaderControl>
    with TimeBatteryMixin {
  @override
  late final plPlayerController = widget.plPlayerController;

  @override
  bool get horizontalScreen => true;

  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;

  @override
  bool get isPortrait => widget.isPortrait;

  @override
  Widget build(BuildContext context) {
    final isFullScreen = this.isFullScreen;
    showCurrTimeIfNeeded(isFullScreen);
    final liveController = widget.liveController;
    Widget child;
    child = Obx(
      key: titleKey,
      () => MarqueeText(
        liveController.title.value,
        spacing: 30,
        velocity: 30,
        strutStyle: const StrutStyle(fontSize: 15, leading: 0),
        style: const TextStyle(fontSize: 15, height: 1, color: Colors.white),
      ),
    );
    if (isFullScreen) {
      child = Column(
        spacing: 5,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Row(
            spacing: 10,
            children: [
              if (widget.upName case final upName?)
                Text(
                  upName,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                  ),
                ),
              liveController.watchedWidget,
              widget.onlineWidget,
              liveController.timeWidget,
            ],
          ),
        ],
      );
    }
    child = Expanded(child: child);

    final compactWindow =
        plPlayerController.isDesktopPip &&
        MediaQuery.sizeOf(context).width < 640;
    const btnHeight = 30.0;

    return Padding(
      padding: const .symmetric(horizontal: 14, vertical: 13),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compactWindow)
            Row(
              children: [
                child,
                DesktopWindowControls(controller: plPlayerController),
              ],
            ),
          Row(
            children: [
              if (isFullScreen && !plPlayerController.isDesktopPip)
                ComBtn(
                  height: btnHeight,
                  tooltip: '返回',
                  icon: Icon(FontAwesomeIcons.arrowLeft.data, size: 15),
                  onTap: () {
                    plPlayerController.triggerFullScreen(status: false);
                  },
                ),
              if (!compactWindow) child else const Spacer(),
              ...?timeBatteryWidgets,
              const SizedBox(width: 10),
              if (PlatformUtils.isDesktop)
                Obx(() {
                  final isAlwaysOnTop = plPlayerController.isAlwaysOnTop.value;
                  return ComBtn(
                    height: btnHeight,
                    tooltip: '${isAlwaysOnTop ? '取消' : ''}置顶',
                    icon: isAlwaysOnTop
                        ? const Icon(
                            size: 18,
                            Icons.push_pin,
                            color: Colors.white,
                          )
                        : const Icon(
                            size: 18,
                            Icons.push_pin_outlined,
                            color: Colors.white,
                          ),
                    onTap: () =>
                        plPlayerController.setAlwaysOnTop(!isAlwaysOnTop),
                  );
                }),
              if (isFullScreen || PlatformUtils.isDesktop)
                ComBtn(
                  height: btnHeight,
                  tooltip: '发弹幕',
                  icon: const Icon(
                    size: 18,
                    Icons.comment_outlined,
                    color: Colors.white,
                  ),
                  onTap: widget.onSendDanmaku,
                ),
              if (PlatformUtils.isDesktop)
                DesktopPlaybackMenu(controller: plPlayerController),
              if (Platform.isAndroid)
                ComBtn(
                  height: btnHeight,
                  tooltip: '画中画',
                  onTap: () {
                    if (PlatformUtils.isDesktop) {
                      plPlayerController.toggleDesktopPip();
                      return;
                    }
                    if (AndroidHelper.isPipAvailable) {
                      plPlayerController.enterPip();
                    }
                  },
                  icon: const Icon(
                    size: 18,
                    Icons.picture_in_picture_outlined,
                    color: Colors.white,
                  ),
                ),
              Obx(
                () => ComBtn(
                  height: btnHeight,
                  tooltip: '仅播放音频',
                  onTap: () {
                    plPlayerController.onlyPlayAudio.toggle();
                    widget.onPlayAudio();
                  },
                  icon: plPlayerController.onlyPlayAudio.value
                      ? const Icon(
                          size: 18,
                          MdiIcons.musicCircle,
                          color: Colors.white,
                        )
                      : const Icon(
                          size: 18,
                          MdiIcons.musicCircleOutline,
                          color: Colors.white,
                        ),
                ),
              ),
              if (PlatformUtils.isMobile)
                Obx(() {
                  final continuePlayInBackground =
                      plPlayerController.continuePlayInBackground.value;
                  return ComBtn(
                    height: btnHeight,
                    tooltip: '${continuePlayInBackground ? '关闭' : ''}后台播放',
                    onTap: plPlayerController.setContinuePlayInBackground,
                    icon: continuePlayInBackground
                        ? const Icon(
                            size: 18,
                            Icons.play_circle,
                            color: Colors.white,
                          )
                        : const Icon(
                            size: 18,
                            Icons.play_circle_outline,
                            color: Colors.white,
                          ),
                  );
                }),
              ComBtn(
                height: btnHeight,
                tooltip: '定时关闭',
                onTap: () => shutdownTimerService.showScheduleExitDialog(
                  context,
                  isFullScreen: isFullScreen,
                  isLive: true,
                ),
                icon: const Icon(
                  size: 18,
                  Icons.schedule,
                  color: Colors.white,
                ),
              ),
              if (plPlayerController.videoPlayerController case final player?)
                SizedBox.square(
                  dimension: 30,
                  child: PopupMenuButton(
                    iconSize: 18,
                    padding: .zero,
                    iconColor: Colors.white,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        height: 35,
                        onTap: _showLiveStreamDialog,
                        child: const Row(
                          spacing: 8,
                          children: [
                            Icon(Icons.alt_route, size: 17),
                            Text('播放线路', style: TextStyle(fontSize: 14)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        height: 35,
                        child: const Row(
                          spacing: 8,
                          children: [
                            Icon(Icons.info_outline, size: 17),
                            Text('播放信息', style: TextStyle(fontSize: 14)),
                          ],
                        ),
                        onTap: () => HeaderControlState.showPlayerInfo(
                          context,
                          player: player,
                        ),
                      ),
                      if (PlatformUtils.isMobile)
                        PopupMenuItem(
                          height: 35,
                          child: Row(
                            spacing: 8,
                            children: [
                              const Icon(Icons.volume_up, size: 17),
                              Text(
                                '播放器音量: ${player.getProperty('volume').subLength(3)}%',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
                          onTap: () => showPlayerVolumeDialog(
                            context,
                            () {},
                            onChanged: player.setVolume,
                          ),
                        ),
                    ],
                  ),
                ),
              if (plPlayerController.isDesktopPip && !compactWindow)
                DesktopWindowControls(controller: plPlayerController),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showLiveStreamDialog() async {
    final controller = widget.liveController;
    plPlayerController.setControlsMenuOpen(true);
    Widget panel(BuildContext context) => LiveStreamPanel(
      streams: controller.stream,
      current: (
        stream: controller.streamIndex,
        format: controller.formatIndex,
        codec: controller.codecIndex,
        url: controller.liveUrlIndex,
      ),
      onClose: () => Navigator.of(context).pop(),
      onSelected: (selection) {
        Navigator.of(context).pop();
        controller.initLiveUrl(
          streamIndex: selection.stream,
          formatIndex: selection.format,
          codecIndex: selection.codec,
          liveUrlIndex: selection.url,
        );
        final stream = controller.stream[selection.stream];
        final format = stream.format[selection.format];
        final codec = format.codec[selection.codec];
        GStorage.setting.put(SettingBoxKey.liveStream, [
          stream.protocolName,
          format.formatName,
          codec.codecName,
        ]);
      },
    );
    try {
      if (PlatformUtils.isDesktop) {
        await showDialog<void>(
          context: context,
          barrierColor: Colors.black26,
          builder: (context) => Dialog(
            backgroundColor: const Color(0xE6202020),
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: math.max(0, MediaQuery.sizeOf(context).height - 48),
            ),
            child: panel(context),
          ),
        );
      } else {
        await showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: const Color(0xE6202020),
          constraints: BoxConstraints(
            maxWidth: math.min(640, context.mediaQueryShortestSide),
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          builder: panel,
        );
      }
    } finally {
      plPlayerController.setControlsMenuOpen(false);
    }
  }
}
