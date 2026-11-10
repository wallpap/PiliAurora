import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/list.dart';
import 'package:pili_aurora/pages/common/multi_select/multi_select_controller.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';

class FavPgcController
    extends MultiSelectController<FavPgcData, FavPgcItemModel> {
  FavPgcController(this.type, this.followStatus, {this.scope});

  final int type;
  final int followStatus;
  final String? scope;
  String tagForStatus(int status) => '${scope ?? 'favPgc'}:$type:$status';

  var _account = Accounts.main;
  Object _context = Object();
  int _mutationEpoch = 0;
  final pendingIds = <int>{}.obs;

  @override
  Object get queryContext {
    if (!identical(_account, Accounts.main)) {
      _account = Accounts.main;
      _context = Object();
    }
    return _context;
  }

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    if (identical(_account, Accounts.main)) return;
    _mutationEpoch++;
    pendingIds.clear();
    onReload();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    _mutationEpoch++;
    super.onClose();
  }

  @override
  final RxBool allSelected = false.obs;

  @override
  void handleSelect({bool checked = false, bool disableSelect = true}) {
    allSelected.value = checked;
    super.handleSelect(checked: checked, disableSelect: disableSelect);
  }

  @override
  Future<void> onRefresh() {
    rxCount.value = 0;
    allSelected.value = false;
    enableMultiSelect.value = false;
    return super.onRefresh();
  }

  @override
  List<FavPgcItemModel>? getDataList(FavPgcData response) => response.list;

  @override
  bool get refillFilteredPages => true;

  @override
  List<FavPgcItemModel> filterList(
    List<FavPgcItemModel> source,
    bool isRefresh,
  ) {
    final seen = <int>{
      if (!isRefresh)
        for (final item in loadingState.value.dataOrNull ?? []) ?item.seasonId,
    };
    return [
      for (final item in source)
        if (item.seasonId == null || seen.add(item.seasonId!)) item,
    ];
  }

  @override
  Future<LoadingState<FavPgcData>> customGetData() => FavHttp.favPgc(
    type: type,
    followStatus: followStatus,
    pn: page,
    account: Accounts.main,
  );

  void onDisable() {
    if (checkedCount != 0) handleSelect();
    enableMultiSelect.value = false;
  }

  bool owns(FavPgcItemModel item) =>
      !isClosed &&
      identical(_account, Accounts.main) &&
      loadingState.value.dataOrNull?.contains(item) == true;

  Future<void> _write(List<FavPgcItemModel> items, {int? status}) async {
    final list = loadingState.value.dataOrNull;
    if (items.isEmpty || list == null || items.any((item) => !owns(item))) {
      return;
    }
    final ids = {for (final item in items) ?item.seasonId};
    if (ids.length != items.length || ids.any((id) => id <= 0)) {
      SmartDialog.showToast('番剧信息不完整，请刷新后重试');
      return;
    }
    if (ids.any(pendingIds.contains)) return;
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final epoch = _mutationEpoch;
    pendingIds.addAll(ids);
    try {
      final result = status == null
          ? await VideoHttp.pgcDel(seasonId: ids.single, account: account)
          : await VideoHttp.pgcUpdate(
              seasonId: ids.join(','),
              status: status,
              account: account,
            );
      if (isClosed ||
          epoch != _mutationEpoch ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      if (result case Success(:final response)) {
        // 写入后分页偏移会前移；从边界重读并去重，避免跳过尚未显示的条目。
        _context = Object();
        page = 1;
        isEnd = false;
        list.removeWhere((item) => ids.contains(item.seasonId));
        rxCount.value = list.where((item) => item.checked).length;
        enableMultiSelect.value = checkedCount > 0;
        allSelected.value = list.isNotEmpty && checkedCount == list.length;
        loadingState.refresh();
        SmartDialog.showToast(response);
        if (status != null) _reloadPeer(status);
      } else {
        result.toast();
      }
    } finally {
      if (epoch == _mutationEpoch) pendingIds.removeAll(ids);
    }
  }

  void _reloadPeer(int status) {
    final tag = tagForStatus(status);
    if (!Get.isRegistered<FavPgcController>(tag: tag)) return;
    final peer = Get.find<FavPgcController>(tag: tag);
    if (peer.isClosed || !identical(peer._account, Accounts.main)) return;
    // 对端刷新失败不改变已经确认的分组写入结果。
    unawaited(
      peer.onReload().catchError((Object error, StackTrace stackTrace) {
        logger.w('刷新追番分组失败', error: error.runtimeType, stackTrace: stackTrace);
      }),
    );
  }

  Future<void> pgcDel(int? seasonId) async {
    final item = loadingState.value.dataOrNull?.firstWhereOrNull(
      (item) => item.seasonId == seasonId,
    );
    if (item != null) await _write([item]);
  }

  @override
  void onRemove() => throw StateError('追番管理应通过分组操作更新');

  Future<void> onUpdateList(int status) => _write([
    for (final item in loadingState.value.dataOrNull ?? <FavPgcItemModel>[])
      if (item.checked) item,
  ], status: status);

  Future<void> onUpdate(int status, int? seasonId) async {
    final item = loadingState.value.dataOrNull?.firstWhereOrNull(
      (item) => item.seasonId == seasonId,
    );
    if (item != null) await _write([item], status: status);
  }
}
