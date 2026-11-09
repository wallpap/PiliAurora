import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/services/desktop_playback_layout.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/logger.dart';

class DesktopPlaybackMenu extends StatelessWidget {
  const DesktopPlaybackMenu({super.key, required this.controller});
  final PlPlayerController controller;

  @override
  Widget build(BuildContext context) => PopupMenuTheme(
    data: Theme.of(context).popupMenuTheme,
    child: PopupMenuButton<String>(
      tooltip: '播放窗口',
      onOpened: () => controller.setControlsMenuOpen(true),
      onCanceled: () => controller.setControlsMenuOpen(false),
      onSelected: (action) async {
        controller.setControlsMenuOpen(false);
        try {
          switch (action) {
            case 'open':
              await controller.openDesktopWindow();
            case 'solo':
              await DesktopPlaybackWindows.instance.solo();
            case 'grid':
              await DesktopPlaybackWindows.instance.arrange(
                DesktopPlaybackLayout.grid,
              );
            case 'cascade':
              await DesktopPlaybackWindows.instance.arrange(
                DesktopPlaybackLayout.cascade,
              );
            case 'close':
              await controller.exitDesktopPip();
          }
        } catch (error, stackTrace) {
          logger.w(
            '播放窗口菜单操作失败：$action',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
          SmartDialog.showToast('播放窗口操作失败，请重试');
        }
      },
      itemBuilder: (_) => [
        if (!DesktopPlaybackWindows.isPlayerWindow)
          AppPopupMenuItem(
            value: 'open',
            enabled: !controller.openingDesktopWindow,
            child: const Text('弹出为独立小窗'),
          ),
        const AppPopupMenuItem(value: 'solo', child: Text('只听这个窗口')),
        AppPopupMenuItem(
          value: 'grid',
          enabled: DesktopPlaybackWindows.instance.canArrange,
          child: const Text('网格排列播放窗口'),
        ),
        AppPopupMenuItem(
          value: 'cascade',
          enabled: DesktopPlaybackWindows.instance.canArrange,
          child: const Text('层叠排列播放窗口'),
        ),
        if (DesktopPlaybackWindows.isPlayerWindow)
          const AppPopupMenuItem(value: 'close', child: Text('关闭播放窗口')),
      ],
      child: Obx(
        () => SizedBox(
          width: 34,
          height: 30,
          child: controller.openingDesktopWindow
              ? const Padding(
                  padding: EdgeInsets.all(7),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(
                  Icons.picture_in_picture_outlined,
                  size: 20,
                  color: Colors.white,
                ),
        ),
      ),
    ),
  );
}
