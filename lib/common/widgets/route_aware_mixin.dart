import 'package:flutter/widgets.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_navigation/src/routes/default_route.dart'
    show GetPageRoute;

final routeObserver = AppRouteObserver();

/// 保留页面的 Get 路由通知，同时为查询导航记录普通路由的生命周期。
class AppRouteObserver extends RouteObserver<GetPageRoute> {
  final _routes = <PageRoute<dynamic>>[];
  final _navigationListeners = <VoidCallback>{};

  Route<dynamic>? get currentRoute => _routes.lastOrNull;

  void addNavigationListener(VoidCallback listener) =>
      _navigationListeners.add(listener);

  void removeNavigationListener(VoidCallback listener) =>
      _navigationListeners.remove(listener);

  void _notifyNavigation() {
    for (final listener in List<VoidCallback>.of(_navigationListeners)) {
      listener();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) _routes.clear();
    // 确认弹窗关闭后仍由来源页面消费结果，只有页面导航使查询失效。
    if (route is PageRoute<dynamic>) {
      _routes.add(route);
      _notifyNavigation();
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final wasCurrent = identical(currentRoute, route);
    _routes.remove(route);
    if (wasCurrent) _notifyNavigation();
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final wasCurrent = identical(currentRoute, route);
    _routes.remove(route);
    if (wasCurrent) _notifyNavigation();
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final wasCurrent = identical(currentRoute, oldRoute);
    final index = _routes.indexWhere((route) => identical(route, oldRoute));
    if (index >= 0) {
      if (newRoute is PageRoute<dynamic>) {
        _routes[index] = newRoute;
      } else {
        _routes.removeAt(index);
      }
    }
    if (wasCurrent) _notifyNavigation();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

mixin RouteAwareMixin<T extends StatefulWidget> on State<T>, RouteAware {
  @override
  void initState() {
    super.initState();
    routeObserver.subscribe(this, Get.routing.route as GetPageRoute);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }
}
