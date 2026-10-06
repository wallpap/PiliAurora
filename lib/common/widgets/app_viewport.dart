import 'package:flutter/widgets.dart';

final viewportInsets = ViewportInsets();

/// 临时保留逻辑像素下的安全区域；每个调用方只能释放自己持有的覆盖值。
class ViewportInsets {
  final _overrides = <Object, EdgeInsets>{};

  EdgeInsets? get padding => _overrides.values.lastOrNull;

  VoidCallback preserve(EdgeInsets padding) {
    final token = Object();
    _overrides[token] = padding;
    return () => _overrides.remove(token);
  }
}

/// 与偏好存储、路由和平台初始化无关的应用视口变换。
class AppViewport extends StatelessWidget {
  const AppViewport({
    super.key,
    required this.uiScale,
    required this.textScale,
    required this.child,
    this.insets,
  }) : assert(uiScale > 0),
       assert(textScale >= 0);

  final double uiScale;
  final double textScale;
  final Widget child;
  final ViewportInsets? insets;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final padding = (insets ?? viewportInsets).padding;
    return MediaQuery(
      data: mediaQuery.copyWith(
        textScaler: TextScaler.linear(textScale),
        size: mediaQuery.size / uiScale,
        padding: padding ?? mediaQuery.padding / uiScale,
        viewInsets: mediaQuery.viewInsets / uiScale,
        viewPadding: padding ?? mediaQuery.viewPadding / uiScale,
        devicePixelRatio: mediaQuery.devicePixelRatio * uiScale,
      ),
      child: child,
    );
  }
}
