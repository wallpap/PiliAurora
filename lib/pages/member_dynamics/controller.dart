import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class MemberDynamicsController
    extends CommonListController<DynamicsDataModel, DynamicItemModel> {
  MemberDynamicsController(this.mid);
  int mid;
  String offset = '';
  final _removing = <String, Object>{};
  Object? _topOperation;
  int _queryGeneration = 0;
  int _noGrowthPages = 0;
  final _offsets = <String>{};
  // 已确认删除在本轮查询中保持移除，显式刷新才重新核对服务端快照。
  final _removedIds = <String>{};
  final loadMoreError = Rx<Error?>(null);

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
    _queryGeneration++;
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  Future<void> onRefresh() {
    offset = '';
    _noGrowthPages = 0;
    _offsets.clear();
    _removedIds.clear();
    loadMoreError.value = null;
    return super.onRefresh();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) _queryGeneration++;
    if (!isRefresh &&
        (isEnd || offset == '-1' || loadMoreError.value != null)) {
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  @override
  List<DynamicItemModel>? getDataList(DynamicsDataModel response) {
    offset = response.offset?.isNotEmpty == true ? response.offset! : '-1';
    if (response.hasMore == false || offset == '-1' || !_offsets.add(offset)) {
      isEnd = true;
    }
    return response.items;
  }

  @override
  List<DynamicItemModel> filterList(
    List<DynamicItemModel> source,
    bool isRefresh,
  ) {
    final ids = <String>{
      ..._removedIds,
      if (!isRefresh)
        ...?loadingState.value.dataOrNull?.map((item) => item.idStr.toString()),
    };
    final accepted = source
        .where((item) => ids.add(item.idStr.toString()))
        .toList();
    // 部分接口会循环返回重复内容，即使游标变化也不能无限自动补页。
    _noGrowthPages = !isRefresh && source.isNotEmpty && accepted.isEmpty
        ? _noGrowthPages + 1
        : 0;
    if (_noGrowthPages >= 5) isEnd = true;
    return accepted;
  }

  Future<void> retryLoadMore() {
    loadMoreError.value = null;
    return onLoadMore();
  }

  @override
  Future<LoadingState<DynamicsDataModel>> customGetData() async {
    final account = Accounts.main;
    final target = mid;
    final generation = _queryGeneration;
    final requestedPage = page;
    final result = await MemberHttp.memberDynamic(
      account: account,
      offset: offset,
      mid: target,
    );
    if (!isClosed &&
        generation == _queryGeneration &&
        target == mid &&
        identical(account, Accounts.main)) {
      loadMoreError.value = requestedPage > 1 && result is Error
          ? result
          : null;
    }
    return result;
  }

  bool Function() _itemOwner(DynamicItemModel item) {
    final account = Accounts.main;
    final target = mid;
    final generation = _queryGeneration;
    final source = loadingState.value.dataOrNull;
    return () =>
        !isClosed &&
        !isLoading &&
        generation == _queryGeneration &&
        target == mid &&
        identical(account, Accounts.main) &&
        identical(source, loadingState.value.dataOrNull) &&
        source?.contains(item) == true;
  }

  Future<void> Function(Object) removalAction(DynamicItemModel item) {
    final current = _itemOwner(item);
    return (id) async {
      if (current() && id.toString() == item.idStr.toString()) {
        await onRemove(id);
      }
    };
  }

  Future<void> Function(bool, Object) topAction(DynamicItemModel item) {
    final current = _itemOwner(item);
    return (isTop, id) async {
      if (current() && id.toString() == item.idStr.toString()) {
        await onSetTop(isTop, id);
      }
    };
  }

  Future<void> onRemove(dynamic dynamicId) async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    final id = dynamicId.toString();
    final targetMid = mid;
    if (isClosed ||
        isLoading ||
        !account.isLogin ||
        account.mid != targetMid ||
        list == null ||
        !list.any((item) => item.idStr.toString() == id) ||
        _topOperation != null ||
        _removing.containsKey(id) ||
        (int.tryParse(id) ?? 0) <= 0) {
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
        _removedIds.add(id);
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
        account.mid != targetMid ||
        list == null ||
        item == null ||
        _topOperation != null ||
        _removing.isNotEmpty) {
      return;
    }
    final currentlyTop =
        item.modules.moduleAuthor?.isTop == true ||
        item.modules.moduleTag?.text == '置顶';
    if (isTop != currentlyTop || (int.tryParse(dynamicId.toString()) ?? 0) <= 0) {
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
