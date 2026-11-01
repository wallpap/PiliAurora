import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/inactive_paint_cleanup.dart';

/// 保活标签页仅在进入视口时启用动画与图片；业务状态和滚动位置继续保留。
class TabActivity extends StatelessWidget {
  const TabActivity({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
  });

  final TabController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.animation!]),
    child: child,
    builder: (context, child) => TickerMode(
      // 跨多个标签时 TabBarView 会把起点临时移到终点旁边，两端仍可见。
      enabled: controller.indexIsChanging
          ? index == controller.index || index == controller.previousIndex
          : (controller.animation!.value - index).abs() < 1,
      child: InactivePaintCleanup(child: child!),
    ),
  );
}
