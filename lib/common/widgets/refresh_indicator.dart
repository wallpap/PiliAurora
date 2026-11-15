import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:material_ui/material_ui.dart';

// ignore: camel_case_types
class RefreshIndicator_ extends StatefulWidget {
  const RefreshIndicator_({
    super.key,
    required this.isRefreshing,
  });

  final bool isRefreshing;

  @override
  State<RefreshIndicator_> createState() => _RefreshIndicatorState();
}

class _RefreshIndicatorState extends State<RefreshIndicator_>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _scaleController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
          value: widget.isRefreshing ? 1 : 0,
        )..addStatusListener((status) {
          if (status == AnimationStatus.dismissed) setState(() {});
        });
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(RefreshIndicator_ oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRefreshing != widget.isRefreshing) {
      if (widget.isRefreshing) {
        _scaleController.value = 1;
      } else {
        _scaleController.reverse();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final colorScheme = ColorScheme.of(context);
    _color = colorScheme.isDark
        ? colorScheme.onInverseSurface
        : colorScheme.surface;
  }

  @override
  Widget build(BuildContext context) {
    // 收起动画结束后卸载进度条，缩放为零仍会让其内部 ticker 持续运行。
    if (!widget.isRefreshing && _scaleController.isDismissed) {
      return const SizedBox.shrink();
    }
    return ScaleTransition(
      scale: _scaleController,
      child: Center(
        child: SizedBox.square(
          dimension: 40,
          child: Material(
            type: .circle,
            elevation: 2.0,
            color: _color,
            child: const Padding(
              padding: .all(6),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      ),
    );
  }
}
