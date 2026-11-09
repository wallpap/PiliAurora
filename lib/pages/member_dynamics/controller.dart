import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class MemberDynamicsController
    extends CommonListController<DynamicsDataModel, DynamicItemModel> {
  MemberDynamicsController(this.mid);
  int mid;
  String offset = '';
  final _removing = <String, Object>{};
  Object? _topOperation;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    _removing.clear();
    _topOperation = null;
    onReload();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  Future<void> onRefresh() {
    offset = '';
    return super.onRefresh();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh && (isEnd || offset == '-1')) {
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  @override
  List<DynamicItemModel>? getDataList(DynamicsDataModel response) {
    offset = response.offset?.isNotEmpty == true ? response.offset! : '-1';
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.items;
  }

  @override
  Future<LoadingState<DynamicsDataModel>> customGetData() =>
      MemberHttp.memberDynamic(
        account: Accounts.main,
        offset: offset,
        mid: mid,
      );

  Future<void> onRemove(dynamic dynamicId) async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    final id = dynamicId.toString();
    final targetMid = mid;
    if (isClosed ||
        isLoading ||
        !account.isLogin ||
        list == null ||
        !list.any((item) => item.idStr.toString() == id) ||
        _topOperation != null ||
        _removing.containsKey(id)) {
      return;
    }
    final operation = _removing[id] = Object();
    try {
      final res = await MsgHttp.removeDynamic(account: account, dynIdStr: id);
      if (isClosed ||
          isLoading ||
          mid != targetMid ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull)) {
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

  Future<void> onSetTop(bool isTop, Object dynamicId) async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    final targetMid = mid;
    final item = list
        ?.where((item) => item.idStr.toString() == dynamicId.toString())
        .firstOrNull;
    if (isClosed ||
        isLoading ||
        !account.isLogin ||
        list == null ||
        item == null ||
        _topOperation != null ||
        _removing.isNotEmpty) {
      return;
    }
    final operation = _topOperation = Object();
    try {
      final res = await (isTop
          ? DynamicsHttp.rmTop(account: account, dynamicId: dynamicId)
          : DynamicsHttp.setTop(account: account, dynamicId: dynamicId));
      if (isClosed ||
          isLoading ||
          mid != targetMid ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull) ||
          !list.contains(item)) {
        return;
      }
      if (res.isSuccess) {
        if (!isTop) {
          for (final previous in list) {
            if (previous.modules.moduleAuthor?.isTop == true ||
                previous.modules.moduleTag?.text == '置顶') {
              previous.modules
                ..moduleTag = null
                ..moduleAuthor?.isTop = false;
            }
          }
        }
        item.modules
          ..moduleTag = isTop ? null : ModuleTag(text: '置顶')
          ..moduleAuthor?.isTop = !isTop;
        if (!isTop) {
          list
            ..remove(item)
            ..insert(0, item);
        }
        loadingState.refresh();
        SmartDialog.showToast(isTop ? '取消置顶成功' : '置顶成功');
      } else {
        res.toast();
      }
    } finally {
      if (identical(_topOperation, operation)) _topOperation = null;
    }
  }
}
