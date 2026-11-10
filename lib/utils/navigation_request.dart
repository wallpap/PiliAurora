import 'dart:async' show unawaited;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/services/logger.dart';

/// 查询导航只允许当前页面的最后一次操作交付结果。
final class NavigationRequest with RouteAware {
  NavigationRequest() : _route = Get.routing.route {
    _latest?._invalidate();
    _latest = this;
    if (_route case final GetPageRoute route) {
      routeObserver.subscribe(this, route);
    }
  }

  static NavigationRequest? _latest;
  static int _nextTag = 0;
  final Route<dynamic>? _route;
  final String _tag = 'navigation-query-${_nextTag++}';
  bool _cancelled = false;
  bool _loading = false;

  bool get isCurrent =>
      !_cancelled &&
      identical(_latest, this) &&
      identical(Get.routing.route, _route) &&
      (_route?.isCurrent ?? true);

  void showLoading([String message = '获取中...']) {
    if (!isCurrent) return;
    _loading = true;
    // showLoading 是全局单例；独立 tag 防止旧请求收尾关闭其他操作。
    SmartDialog.show<void>(
      tag: _tag,
      builder: (_) => LoadingWidget(message),
      debounce: false,
      clickMaskDismiss: false,
      backType: SmartBackType.normal,
      onDismiss: () {
        if (_loading) _invalidate();
      },
    );
  }

  Future<void> closeLoading() async {
    if (!_loading) return;
    _loading = false;
    try {
      await SmartDialog.dismiss(tag: _tag);
    } catch (error, stackTrace) {
      logger.w('关闭导航加载提示失败', error: error.runtimeType, stackTrace: stackTrace);
    }
  }

  void _invalidate() {
    _cancelled = true;
    unawaited(closeLoading());
  }

  @override
  void didPushNext() => _invalidate();

  @override
  void didPop() => _invalidate();

  Future<void> close() async {
    routeObserver.unsubscribe(this);
    if (identical(_latest, this)) _latest = null;
    _cancelled = true;
    await closeLoading();
  }
}
