import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonDataController<R, T> extends CommonController<R, T> {
  @override
  Rx<LoadingState<T>> loadingState = LoadingState<T>.loading().obs;

  @override
  void applyResponse(bool isRefresh, Success<R> response) {
    if (!customHandleResponse(isRefresh, response)) {
      loadingState.value = Success(response.response as T);
    }
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<T>.loading();
    return super.onReload();
  }
}
