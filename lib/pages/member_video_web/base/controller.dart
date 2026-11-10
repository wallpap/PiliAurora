import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show ReloadMixin;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:get/get.dart';

const int ps = 30;

abstract class BaseVideoWebCtr<R, T, V> extends CommonListController<R, T>
    with ReloadMixin {
  BaseVideoWebCtr({Object? mid}) : mid = mid ?? Get.arguments['mid'];

  final Object mid;

  int? totalPage;
  int? count;
  Rx<V> get order;

  @override
  Object get queryContext => Accounts.main;

  void _onAccountChanged() {
    resetMetadata();
    onReload();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  @override
  void checkIsEnd(int length) {
    if (totalPage != null && page >= totalPage!) {
      isEnd = true;
    } else if (count != null && length >= count!) {
      isEnd = true;
    }
  }

  void queryBySort(V value) {
    if (isLoading) return;
    order.value = value;
    onReload();
  }

  void jumpToPage(int page) {
    if (isClosed || page < 1 || (totalPage != null && page > totalPage!)) {
      return;
    }
    isEnd = false;
    reload = true;
    this.page = page;
    loadingState.value = LoadingState.loading();
    queryData();
  }

  void resetMetadata() {}

  @override
  Future<void> onRefresh() {
    totalPage = null;
    count = null;
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    reload = true;
    return super.onReload();
  }
}
