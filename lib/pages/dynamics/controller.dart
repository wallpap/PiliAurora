import 'dart:async';

import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/dynamic/dynamics_type.dart';
import 'package:pili_aurora/models/dynamics/up.dart';
import 'package:pili_aurora/pages/common/common_data_controller.dart';
import 'package:pili_aurora/pages/dynamics_tab/controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class DynamicsController
    extends CommonDataController<FollowUpModel, FollowUpModel>
    with GetSingleTickerProviderStateMixin {
  late final TabController tabController;

  final Set<int> tempBannedList = <int>{};

  String? _offset;
  late int _page = 1;
  late bool _isEnd = false;
  bool _dynamicEnd = false;
  final _seenOffsets = <String>{};
  final _upByMid = <int, UpItem>{};
  int _addedUpCount = 0;
  late int hostMid = -1, currentMid = -1;
  late bool showLiveUp = Pref.expandDynLivePanel;
  late final _showAllUp = Pref.dynamicsShowAllFollowedUp;

  final upPanelPosition = Pref.upPanelPosition;

  final AccountService accountService = Get.find<AccountService>();

  @override
  Object get queryContext => Accounts.main;

  @override
  bool get canLoadMore => !_isEnd && loadingState.value.dataOrNull != null;

  DynamicsTabController? get controller {
    try {
      return Get.find<DynamicsTabController>(
        tag: DynamicsTabType.values[tabController.index].name,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(
      vsync: this,
      length: DynamicsTabType.values.length,
      initialIndex: Pref.defaultDynamicTypeIndex,
    );
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    loadingState.value = LoadingState.loading();
    singleRefresh();
  }

  void _jumpToTab(int mid) {
    tabController.index = mid == -1 ? 0 : 4;
  }

  void onSelectUp(int mid) {
    if (currentMid == mid) {
      _jumpToTab(mid);
      if (mid == -1) {
        singleRefresh();
      }
      controller?.onReload();
      return;
    }

    if (mid != -1) {
      hostMid = mid;
      try {
        Get.find<DynamicsTabController>(
          tag: DynamicsTabType.up.name,
        ).onReload();
      } catch (_) {}
    }

    currentMid = mid;
    _jumpToTab(mid);
  }

  Future<void> singleRefresh() => super.onRefresh();

  @override
  Future<void> onRefresh() async {
    final controller = this.controller;
    await Future.wait([
      singleRefresh(),
      if (controller != null) controller.onRefresh(),
    ]);
  }

  @override
  void animateToTop() {
    controller?.animateToTop();
    scrollController.animToTop();
  }

  @override
  void toTopOrRefresh() {
    final ctr = controller;
    if (ctr?.scrollController.hasClients == true) {
      if (ctr!.scrollController.position.pixels == 0) {
        if (scrollController.hasClients &&
            scrollController.position.pixels != 0) {
          scrollController.animToTop();
        }
        ActionThrottle.run(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          onRefresh,
        );
      } else {
        animateToTop();
      }
    } else {
      super.toTopOrRefresh();
    }
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    tabController.dispose();
    super.onClose();
  }

  @override
  Future<LoadingState<FollowUpModel>> customGetData() {
    final account = Accounts.main;
    if (_offset == null && !_dynamicEnd) {
      return DynamicsHttp.followUp(account: account);
    }
    if (_dynamicEnd) {
      return DynamicsHttp.followings(
        account: account,
        vmid: account.mid,
        pn: _page,
        orderType: 'attention',
        ps: 50,
      );
    } else {
      return DynamicsHttp.dynUpList(_offset, account: account);
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) {
      _offset = null;
      _page = 1;
      _isEnd = false;
      _dynamicEnd = false;
      _seenOffsets.clear();
      _upByMid.clear();
    } else if (_isEnd) {
      return Future.value();
    }
    return super.queryData(isRefresh);
  }

  @override
  int remainingItemsToLoad(int remaining) => _addedUpCount == 0 ? 1 : 0;

  @override
  bool customHandleResponse(bool isRefresh, Success<FollowUpModel> response) {
    final res = response.response;
    final followingPage = !isRefresh && _dynamicEnd;
    var items = res.upList ?? <UpItem>[];
    if (followingPage) {
      _page++;
      _isEnd = items.isEmpty;
    } else {
      final offset = res.offset;
      final repeated = offset != null && !_seenOffsets.add(offset);
      _dynamicEnd =
          res.hasMore != true || offset == null || offset.isEmpty || repeated;
      _offset = offset;
      if (!_showAllUp) _isEnd = _dynamicEnd;
      if (repeated && !isRefresh) items = [];
    }

    _addedUpCount = 0;
    for (final item in items) {
      final existing = _upByMid[item.mid];
      if (existing == null) {
        _upByMid[item.mid] = item;
        _addedUpCount++;
      } else {
        existing.face ??= item.face;
        existing.uname ??= item.uname;
        // 资料补齐和重复动态页不撤销用户在本轮查询中标记的已读状态。
        existing.hasUpdate ??= item.hasUpdate;
      }
    }
    final merged = _upByMid.values.toList();
    // 稳定分组：续页中的未读作者仍排在普通关注之前。
    final ordered = [
      ...merged.where((up) => up.hasUpdate == true),
      ...merged.where((up) => up.hasUpdate != true),
    ];
    if (isRefresh) {
      res.upList = ordered;
      loadingState.value = response;
    } else {
      loadingState
        ..value.data.upList = ordered
        ..refresh();
    }
    return true;
  }
}
