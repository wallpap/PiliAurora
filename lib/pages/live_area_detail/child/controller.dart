import 'dart:math';

import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_data_list_item.dart';
import 'package:pili_aurora/models/remote/live/live_second_list/data.dart';
import 'package:pili_aurora/models/remote/live/live_second_list/tag.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:get/get.dart';

class LiveAreaChildController
    extends DiscoveryListController<LiveSecondData, CardLiveItem> {
  LiveAreaChildController(this.areaId, this.parentAreaId);
  final dynamic areaId;
  final dynamic parentAreaId;

  int? count;

  String? sortType;

  // tag
  final RxInt tagIndex = 0.obs;
  List<LiveSecondTag>? newTags;
  Account _contextMain = Accounts.main;
  Account _contextRecommend = LiveHttp.recommend;
  Object _queryContext = Object();

  @override
  Object get queryContext {
    final main = Accounts.main;
    final recommend = LiveHttp.recommend;
    if (!identical(main, _contextMain) ||
        !identical(recommend, _contextRecommend)) {
      _contextMain = main;
      _contextRecommend = recommend;
      _queryContext = Object();
    }
    return _queryContext;
  }

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    Accounts.recommendChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    final previous = _queryContext;
    if (identical(previous, queryContext)) return;
    count = null;
    newTags = null;
    onReload();
  }

  @override
  void checkIsEnd(int length) {
    if (count != null && length >= count!) {
      isEnd = true;
    }
  }

  @override
  List<CardLiveItem>? getDataList(LiveSecondData response) {
    count = response.count;
    newTags = response.newTags;
    tagIndex.value = max(
      0,
      newTags?.indexWhere((e) => e.sortType == sortType) ?? 0,
    );
    return response.cardList;
  }

  @override
  Future<LoadingState<LiveSecondData>> customGetData() =>
      LiveHttp.liveSecondList(
        pn: page,
        areaId: areaId,
        parentAreaId: parentAreaId,
        sortType: sortType,
      );

  void onSelectTag(int index, String? sortType) {
    if (isLoading) {
      return;
    }
    tagIndex.value = index;
    this.sortType = sortType;

    onRefresh();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    Accounts.recommendChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}
