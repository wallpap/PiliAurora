import 'package:pili_aurora/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

Widget tabBarView({
  required List<Widget> children,
  TabController? controller,
  HitTestBehavior hitTestBehavior = .opaque,
}) => TabBarView(
  controller: controller,
  physics: tabBarScrollPhysics,
  hitTestBehavior: hitTestBehavior,
  horizontalDragGestureRecognizer: CustomHorizontalDragGestureRecognizer.new,
  children: children,
);

SpringDescription kSpringDescription = _customSpringDescription();

SpringDescription _customSpringDescription() {
  final List<double> springDescription = Pref.springDescription;
  return SpringDescription(
    mass: springDescription[0],
    stiffness: springDescription[1],
    damping: springDescription[2],
  );
}

const tabBarScrollPhysics = _TabBarViewScrollPhysics();

class _TabBarViewScrollPhysics extends ClampingScrollPhysics {
  const _TabBarViewScrollPhysics({super.parent});

  @override
  _TabBarViewScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TabBarViewScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => kSpringDescription;
}

mixin ReloadMixin {
  late bool reload = false;
}

class ReloadScrollPhysics extends AlwaysScrollableScrollPhysics {
  const ReloadScrollPhysics({super.parent, required this.controller});

  final ReloadMixin controller;

  @override
  ReloadScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ReloadScrollPhysics(
      parent: buildParent(ancestor),
      controller: controller,
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (controller.reload) {
      controller.reload = false;
      return 0;
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

const platformClampingPhysics = ClampingScrollPhysics();

const platformAlwaysClampingPhysics = AlwaysScrollableScrollPhysics(
  parent: ClampingScrollPhysics(),
);
