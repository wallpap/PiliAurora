import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Windows 保活页面隐藏时回收列表卡片，保留页面状态和滚动位置。
///
/// 直接包住 SliverGrid/SliverList，页头、页脚和 SliverPadding 留在范围外。
/// 卡片遵循正常的列表回收规则，显式请求 KeepAlive 的卡片仍会保留。
class InactiveFeedSliver extends StatelessWidget {
  const InactiveFeedSliver({super.key, required this.sliver});

  final Widget sliver;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return sliver;
    return _InactiveFeedSliver(
      active: TickerMode.valuesOf(context).enabled,
      child: sliver,
    );
  }
}

class _InactiveFeedSliver extends SingleChildRenderObjectWidget {
  const _InactiveFeedSliver({required this.active, required super.child});

  final bool active;

  @override
  _RenderInactiveFeedSliver createRenderObject(BuildContext context) =>
      _RenderInactiveFeedSliver(active);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderInactiveFeedSliver renderObject,
  ) {
    renderObject.active = active;
  }
}

class _RenderInactiveFeedSliver extends RenderProxySliver {
  _RenderInactiveFeedSliver(this._active);

  bool _active;
  SliverGeometry? _activeGeometry;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    child!.layout(
      _active
          ? constraints
          : constraints.copyWith(
              remainingPaintExtent: 0,
              // Grid 在非零整行边界不能使用空区间，保留一行即可。
              // 尚未进入父缓存区的列表本来只布局首项，不额外展开它。
              remainingCacheExtent:
                  constraints.scrollOffset == 0 &&
                      constraints.remainingCacheExtent == 0
                  ? 0
                  : 1,
              cacheOrigin: 0,
            ),
      parentUsesSize: true,
    );
    final childGeometry = child!.geometry!;
    // 数据变更引发的真实位置修正必须交给 viewport 处理。
    if (childGeometry.scrollOffsetCorrection != null) {
      geometry = childGeometry;
    } else if (_active) {
      _activeGeometry = geometry = childGeometry;
    } else {
      // 变高列表只留一项时估算总高度会变化，不能因此改写隐藏页 offset。
      geometry = childGeometry.copyWith(
        scrollExtent: _activeGeometry?.scrollExtent,
        maxPaintExtent: _activeGeometry?.maxPaintExtent,
        cacheExtent: 0,
      );
    }
  }
}
