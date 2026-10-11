import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';

/// 首帧后通过现有路由传入播放参数，保持页面与导航观察器的初始化顺序。
class DesktopPlaybackLaunch extends StatefulWidget {
  const DesktopPlaybackLaunch({super.key, required this.request});
  final DesktopPlaybackRequest request;

  @override
  State<DesktopPlaybackLaunch> createState() => _DesktopPlaybackLaunchState();
}

class _DesktopPlaybackLaunchState extends State<DesktopPlaybackLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Get.offNamed(widget.request.route, arguments: widget.request.arguments);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
