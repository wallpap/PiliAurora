import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonListController<R, T>
    extends CommonController<R, List<T>?> {
  int page = 1;
  bool isEnd = false;
  bool? hasFooter;

  @override
  Rx<LoadingState<List<T>?>> loadingState =
      LoadingState<List<T>?>.loading().obs;

  void handleListResponse(List<T> dataList) {}

  List<T>? getDataList(R response) {
    return response as List<T>?;
  }

  void checkIsEnd(int length) {}

  List<T> filterList(List<T> source, bool isRefresh) => source;

  bool get refillFilteredPages => false;

  /// 有独立分页游标的来源不能用过滤后的空列表推断结束。
  bool get emptyPageIsEnd => true;

  int _lastRemovedCount = 0;
  int _lastAcceptedCount = 0;
  int _sourceCount = 0;

  @override
  int remainingItemsToLoad(int remaining) {
    if (!refillFilteredPages) return 0;
    if (_lastRemovedCount == 0 && _lastAcceptedCount == 0) return 0;
    return remaining > 0 ? remaining - _lastAcceptedCount : _lastRemovedCount;
  }

  @override
  bool get canLoadMore => !isEnd && loadingState.value.dataOrNull != null;

  @override
  void applyResponse(bool isRefresh, Success<R> response) {
    _lastRemovedCount = 0;
    _lastAcceptedCount = 0;
    if (customHandleResponse(isRefresh, response)) {
      page++;
      return;
    }
    final source = getDataList(response.response);
    if (source == null || source.isEmpty) {
      if (emptyPageIsEnd) isEnd = true;
      if (isRefresh) {
        loadingState.value = Success(source);
      } else if (hasFooter == true) {
        loadingState.refresh();
      }
      return;
    }
    // 列表处理钩子也可能插入历史推荐项，先取得所有权再交给业务逻辑。
    final data = filterList(List<T>.of(source), isRefresh);
    _lastAcceptedCount = data.length;
    _lastRemovedCount = source.length - data.length;
    _sourceCount = (isRefresh ? 0 : _sourceCount) + source.length;
    handleListResponse(data);
    if (isRefresh) {
      checkIsEnd(refillFilteredPages ? _sourceCount : data.length);
      loadingState.value = Success(data);
    } else {
      final current = loadingState.value.data!..addAll(data);
      checkIsEnd(refillFilteredPages ? _sourceCount : current.length);
      loadingState.refresh();
    }
    page++;
  }

  @override
  Future<void> onRefresh() {
    page = 1;
    isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<List<T>?>.loading();
    return super.onReload();
  }
}
