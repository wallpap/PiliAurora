import 'package:flutter/gestures.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

double desktopVolumeAfterScroll(
  double volume,
  double delta,
  double maxVolume,
) => (volume - delta / 4000).clamp(0.0, maxVolume);

/// 点击展开竖向音量条；浮层沿用播放器的滚轮和快捷键交互。
class DesktopVolumeControl extends StatefulWidget {
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
  State<DesktopVolumeControl> createState() => _DesktopVolumeControlState();
}

class _DesktopVolumeControlState extends State<DesktopVolumeControl> {
  final _overlay = OverlayPortalController();

  void _close() {
    if (!_overlay.isShowing) return;
    _overlay.hide();
    widget.onClosed?.call();
  }

  void _toggle() {
    if (_overlay.isShowing) {
      _close();
    } else {
      _overlay.show();
      widget.onOpened?.call();
    }
  }

  void _onScroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      // 由命中的音量控件消费一次，避免播放器画面重复处理同一滚轮事件。
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        widget.onChanged(
          desktopVolumeAfterScroll(
            widget.volume.value,
            event.scrollDelta.dy,
            widget.maxVolume,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    if (_overlay.isShowing) widget.onClosed?.call();
    super.dispose();
  }

  IconData get _icon => widget.muted.value || widget.volume.value == 0
      ? Icons.volume_off
      : Icons.volume_up;

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: this,
    onTapOutside: (_) => _close(),
    child: OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: (context, info) {
        const width = 56.0;
        final anchor = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        final left = (anchor.center.dx - width / 2).clamp(
          0.0,
          (info.overlaySize.width - width).clamp(0.0, double.infinity),
        );
        final above = anchor.top - 8;
        final below = info.overlaySize.height - anchor.bottom - 8;
        final openAbove = above >= below;
        final height = (openAbove ? above : below).clamp(0.0, 184.0);
        final top = openAbove ? anchor.top - height - 8 : anchor.bottom + 8;
        return Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: TapRegion(
            groupId: this,
            consumeOutsideTaps: true,
            child: Listener(
              onPointerSignal: _onScroll,
              child: Material(
                color: const Color(0xD9202020),
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: Obx(
                  () => Column(
                    children: [
                      const SizedBox(height: 10),
                      Text(
                        '${(widget.volume.value * 100).round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              activeTrackColor: ColorScheme.of(context).primary,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: ColorScheme.of(context).primary,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              showValueIndicator: ShowValueIndicator.never,
                            ),
                            child: Slider(
                              value: widget.volume.value.clamp(
                                0.0,
                                widget.maxVolume,
                              ),
                              max: widget.maxVolume,
                              semanticFormatterCallback: (value) =>
                                  '${(value * 100).round()}%',
                              onChanged: widget.onChanged,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 34,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: widget.muted.value ? '取消静音' : '静音',
                          onPressed: () =>
                              widget.onMuteChanged(!widget.muted.value),
                          icon: Icon(_icon, color: Colors.white, size: 18),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Listener(
        onPointerSignal: _onScroll,
        child: Obx(
          () => SizedBox(
            width: 34,
            height: 30,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: widget.muted.value
                  ? '音量：静音'
                  : '音量：${(widget.volume.value * 100).round()}%',
              onPressed: _toggle,
              icon: Icon(_icon, size: 20, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
}
