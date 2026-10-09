import 'package:flutter/material.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_handoff.dart';

/// 快照与活纹理共用外侧 FittedBox 的坐标空间；不隐藏底层 Texture，
/// 它必须继续被 raster 消费，才能收到本次提交的帧确认。
class VideoOutputHandoffView extends StatelessWidget {
  const VideoOutputHandoffView({
    super.key,
    required this.handoff,
    required this.frameKey,
    required this.child,
  });

  final VideoOutputHandoff handoff;
  final GlobalKey frameKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: handoff,
    child: RepaintBoundary(key: frameKey, child: child),
    builder: (context, liveFrame) => Stack(
      children: [
        liveFrame!,
        if (handoff.image case final image?)
          Positioned.fill(
            child: IgnorePointer(
              child: RawImage(image: image, fit: BoxFit.fill),
            ),
          ),
      ],
    ),
  );
}
