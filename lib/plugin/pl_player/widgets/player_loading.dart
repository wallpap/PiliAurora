import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/duration_utils.dart';

class PlayerLoadingIndicator extends StatelessWidget {
  const PlayerLoadingIndicator({
    super.key,
    this.failed = false,
    this.buffered = 0,
    this.onRetry,
    this.message,
  });

  final bool failed;
  final int buffered;
  final VoidCallback? onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) => Center(
    child: GestureDetector(
      onTap: failed ? onRetry : null,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Colors.black26, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              const Icon(Icons.refresh, size: 25, color: Colors.white)
            else
              const SizedBox.square(
                dimension: 25,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                  semanticsLabel: '加载中',
                ),
              ),
            const SizedBox(height: 6),
            Text(
              message ??
                  (failed
                      ? '加载失败，点击重试'
                      : buffered == 0
                      ? '加载中...'
                      : DurationUtils.formatDuration(buffered)),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 原生输出创建前也保留加载反馈与页面控件。
class PlayerLoadingPanel extends StatelessWidget {
  const PlayerLoadingPanel({
    super.key,
    this.headerControl,
    this.bottomControl,
    this.failed = false,
    this.onRetry,
    this.fill = Colors.black,
  });

  final Widget? headerControl;
  final Widget? bottomControl;
  final bool failed;
  final VoidCallback? onRetry;
  final Color fill;

  @override
  Widget build(BuildContext context) => Material(
    color: fill,
    child: Stack(
      fit: StackFit.expand,
      children: [
        PlayerLoadingIndicator(failed: failed, onRetry: onRetry),
        if (headerControl case final header?)
          Align(alignment: Alignment.topCenter, child: header),
        if (bottomControl case final bottom?)
          Align(alignment: Alignment.bottomCenter, child: bottom),
      ],
    ),
  );
}
