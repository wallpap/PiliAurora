import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/services/desktop_playback_layout.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';

class DesktopPlaybackMenu extends StatelessWidget {
  const DesktopPlaybackMenu({super.key, required this.controller});
  final PlPlayerController controller;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '播放窗口',
    onOpened: () => controller.setControlsMenuOpen(true),
    onCanceled: () => controller.setControlsMenuOpen(false),
    color: const Color(0xEE202020),
    onSelected: (action) {
      controller.setControlsMenuOpen(false);
      switch (action) {
        case 'open':
          controller.openDesktopWindow();
        case 'solo':
          DesktopPlaybackWindows.instance.solo();
        case 'grid':
          DesktopPlaybackWindows.instance.arrange(DesktopPlaybackLayout.grid);
        case 'cascade':
          DesktopPlaybackWindows.instance.arrange(
            DesktopPlaybackLayout.cascade,
          );
        case 'close':
          controller.exitDesktopPip();
      }
    },
    itemBuilder: (_) => [
      if (!DesktopPlaybackWindows.isPlayerWindow)
        const PopupMenuItem(value: 'open', child: Text('弹出为独立小窗')),
      const PopupMenuItem(value: 'solo', child: Text('只听这个窗口')),
      PopupMenuItem(
        value: 'grid',
        enabled: DesktopPlaybackWindows.instance.canArrange,
        child: const Text('网格排列播放窗口'),
      ),
      PopupMenuItem(
        value: 'cascade',
        enabled: DesktopPlaybackWindows.instance.canArrange,
        child: const Text('层叠排列播放窗口'),
      ),
      if (DesktopPlaybackWindows.isPlayerWindow)
        const PopupMenuItem(value: 'close', child: Text('关闭播放窗口')),
    ],
    child: const SizedBox(
      width: 34,
      height: 30,
      child: Icon(
        Icons.picture_in_picture_outlined,
        size: 20,
        color: Colors.white,
      ),
    ),
  );
}
