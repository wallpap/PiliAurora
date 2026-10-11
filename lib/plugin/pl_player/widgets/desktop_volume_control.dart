import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 视频与直播共用音量入口；菜单中的状态随快捷键和滑块同步更新。
class DesktopVolumeControl extends StatelessWidget {
  const DesktopVolumeControl({
    super.key,
    required this.volume,
    required this.muted,
    required this.maxVolume,
    required this.onChanged,
    required this.onMuteChanged,
    this.onOpened,
    this.onClosed,
  });

  final RxDouble volume;
  final RxBool muted;
  final double maxVolume;
  final ValueChanged<double> onChanged;
  final ValueChanged<bool> onMuteChanged;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) => Obx(
    () => PopupMenuButton<void>(
      tooltip: muted.value ? '音量：静音' : '音量：${(volume.value * 100).round()}%',
      onOpened: onOpened,
      onCanceled: onClosed,
      color: const Color(0xEE202020),
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          enabled: false,
          child: SizedBox(
            width: 220,
            child: Obx(
              () => Row(
                children: [
                  IconButton(
                    tooltip: muted.value ? '取消静音' : '静音',
                    onPressed: () => onMuteChanged(!muted.value),
                    icon: Icon(
                      muted.value || volume.value == 0
                          ? Icons.volume_off
                          : Icons.volume_up,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: volume.value.clamp(0.0, maxVolume),
                      max: maxVolume,
                      label: '${(volume.value * 100).round()}%',
                      semanticFormatterCallback: (value) =>
                          '${(value * 100).round()}%',
                      onChanged: onChanged,
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${(volume.value * 100).round()}%',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      child: SizedBox(
        width: 34,
        height: 30,
        child: Icon(
          muted.value || volume.value == 0 ? Icons.volume_off : Icons.volume_up,
          size: 20,
          color: Colors.white,
        ),
      ),
    ),
  );
}
