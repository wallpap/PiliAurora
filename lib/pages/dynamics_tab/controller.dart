import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/common/dynamic/dynamics_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/pages/dynamics/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DynamicsTabController
    extends DiscoveryListController<DynamicsDataModel, DynamicItemModel> {
  DynamicsTabController({required this.dynamicsType});
  final DynamicsTabType dynamicsType;

  String? offset;
  final _removing = <String, Object>{};

  late final mainController = Get.find<MainController>();
  final dynamicsController = Get.find<DynamicsController>();

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    _removing.clear();
    onReload();
  }

  @override
  Future<void> onRefresh() {
    if (dynamicsType == .all) {
      mainController.setDynCount();
    }
    offset = null;
    return super.onRefresh();
  }

  @override
  List<DynamicItemModel>? getDataList(DynamicsDataModel response) {
    if (response.hasMore == false ||
        (offset != null && response.offset == offset)) {
      isEnd = true;
    }
    offset = response.offset;
    return response.items;
  }

  @override
  Future<LoadingState<DynamicsDataModel>> customGetData() =>
      DynamicsHttp.followDynamic(
        account: Accounts.main,
        offset: offset,
        type: dynamicsType,
        hostMid: dynamicsController.hostMid,
        tempBannedList: dynamicsController.tempBannedList,
      );

  Future<void> onRemove(int index, dynamic dynamicId) async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    final hostMid = dynamicsController.hostMid;
    final id = dynamicId.toString();
    if (isClosed ||
        isLoading ||
        !account.isLogin ||
        list == null ||
        !list.any((item) => item.idStr.toString() == id) ||
        _removing.containsKey(id)) {
      return;
    }
    final operation = _removing[id] = Object();
    try {
      final res = await MsgHttp.removeDynamic(account: account, dynIdStr: id);
      if (isClosed ||
          isLoading ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull) ||
          (dynamicsType == .up && hostMid != dynamicsController.hostMid)) {
        return;
      }
      if (res.isSuccess) {
        list.removeWhere((item) => item.idStr.toString() == id);
        loadingState.refresh();
        SmartDialog.showToast('删除成功');
      } else {
        res.toast();
      }
    } finally {
      if (identical(_removing[id], operation)) _removing.remove(id);
    }
  }

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }

  void onBlock(int index) {
    final list = loadingState.value.dataOrNull;
    if (dynamicsType != .up &&
        list != null &&
        index >= 0 &&
        index < list.length) {
      list.removeAt(index);
      loadingState.refresh();
    }
  }

  void onUnfold(DynamicItemModel item, int index) {
    final list = loadingState.value.dataOrNull;
    final ids = item.modules.moduleFold?.ids?.toSet();
    if (list == null || ids == null || !list.contains(item)) return;
    for (final candidate in list) {
      if (ids.contains(candidate.idStr.toString())) candidate.visible = true;
    }
    item.modules.moduleFold = null;
    loadingState.refresh();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}
