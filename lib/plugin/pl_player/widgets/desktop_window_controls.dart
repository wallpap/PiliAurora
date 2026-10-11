import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:window_manager/window_manager.dart';

/// 独立播放窗口始终提供明确的窗口操作入口。
class DesktopWindowControls extends StatelessWidget {
  const DesktopWindowControls({super.key, required this.controller});
  final PlPlayerController controller;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _button('最小化', Icons.remove, () async {
        if (controller.isFullScreen.value) {
          await controller.triggerFullScreen(status: false);
        }
        await windowManager.minimize();
      }),
      Obx(
        () => _button(
          controller.isFullScreen.value ? '退出全屏' : '全屏',
          controller.isFullScreen.value
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
          () => controller.triggerFullScreen(
            status: !controller.isFullScreen.value,
          ),
        ),
      ),
      _button('关闭播放窗口', Icons.close, controller.exitDesktopPip),
    ],
  );

  Widget _button(String tooltip, IconData icon, VoidCallback onPressed) =>
      SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(icon, color: Colors.white, size: 19),
        ),
      );
}
