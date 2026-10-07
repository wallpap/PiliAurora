import 'dart:async';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

mixin ScrollOrRefreshMixin {
  ScrollController get scrollController;

  void animateToTop() => scrollController.animToTop();

  Future<void> onRefresh();

  void toTopOrRefresh() {
    if (scrollController.hasClients) {
      if (scrollController.position.pixels == 0) {
        ActionThrottle.run(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          onRefresh,
        );
      } else {
        animateToTop();
      }
    }
  }
}

abstract class CommonController<R, T> extends GetxController
    with ScrollOrRefreshMixin {
  @override
  final ScrollController scrollController = ScrollController();

  int _requestVersion = 0;
  bool _isLoading = false;
  bool _disposed = false;

  bool get isLoading => _isLoading;
  Rx<LoadingState<T>> get loadingState;

  /// 数据控制器默认可继续请求；列表控制器同时检查首屏数据和分页终点。
  bool get canLoadMore => true;

  Future<LoadingState<R>> customGetData();

  /// 刷新替换当前查询；加载更多串行执行，不让旧响应写回新的页面状态。
  /// 不假装取消 HTTP 请求，只取消其对当前控制器的写回资格。
  Future<void> queryData([bool isRefresh = true]) async {
    if (_disposed || (!isRefresh && (isLoading || !canLoadMore))) return;
    final version = ++_requestVersion;
    _isLoading = true;
    try {
      final response = await customGetData();
      if (_disposed || version != _requestVersion) return;
      switch (response) {
        case Success<R>():
          applyResponse(isRefresh, response);
        case Error(:final errMsg):
          if (isRefresh && !handleError(errMsg)) {
            loadingState.value = response;
          }
        case Loading():
          // 请求实现没有返回终态时，保留页面当前状态而不是强制转换成 Error。
          break;
      }
    } finally {
      // 旧请求完成时不能释放后来请求的加载标记。
      if (version == _requestVersion) _isLoading = false;
    }
  }

  void applyResponse(bool isRefresh, Success<R> response);

  bool customHandleResponse(bool isRefresh, Success<R> response) {
    return false;
  }

  bool handleError(String? errMsg) {
    return false;
  }

  @override
  Future<void> onRefresh() {
    return queryData();
  }

  Future<void> onLoadMore() {
    return queryData(false);
  }

  Future<void> onReload() {
    return onRefresh();
  }

  @override
  void onClose() {
    _disposed = true;
    _requestVersion++;
    _isLoading = false;
    scrollController.dispose();
    super.onClose();
  }
}
