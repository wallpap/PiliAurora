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

  @override
  bool get canLoadMore => !isEnd && loadingState.value.dataOrNull != null;

  @override
  void applyResponse(bool isRefresh, Success<R> response) {
    if (customHandleResponse(isRefresh, response)) {
      page++;
      return;
    }
    final source = getDataList(response.response);
    if (source == null || source.isEmpty) {
      isEnd = true;
      if (isRefresh) {
        loadingState.value = Success(source);
      } else if (hasFooter == true) {
        loadingState.refresh();
      }
      return;
    }
    // 列表处理钩子也可能插入历史推荐项，先取得所有权再交给业务逻辑。
    final data = List<T>.of(source);
    handleListResponse(data);
    if (isRefresh) {
      checkIsEnd(data.length);
      loadingState.value = Success(data);
    } else {
      final current = loadingState.value.data!..addAll(data);
      checkIsEnd(current.length);
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
