
import 'package:material_ui/material_ui.dart' show ScrollPhysics, ScrollMetrics;

typedef OnDrag = bool Function(double offset);

mixin RefreshScrollPhysicsMixin on ScrollPhysics {
  OnDrag get onDrag;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset < 0.0 && onDrag(offset)) {
      return 0.0;
    }
    return parent?.applyPhysicsToUserOffset(position, offset) ?? offset;
  }
}
