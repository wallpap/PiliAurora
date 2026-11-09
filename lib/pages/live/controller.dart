import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_data_list_item.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_list.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/data.dart';
import 'package:pili_aurora/models/remote/live/live_second_list/data.dart';
import 'package:pili_aurora/models/remote/live/live_second_list/tag.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

class LiveController extends DiscoveryListController {
  Account _contextMain = Accounts.main;
  Account _contextRecommend = LiveHttp.recommend;
  Object _queryContext = Object();
  int _topVersion = 0;

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
    topState.value = Pair(first: null, second: null);
    newTags = null;
    onReload();
  }

  int? count;

  // area
  int? areaId;
  String? sortType;
  int? parentAreaId;
  final RxInt areaIndex = 0.obs;

  // tag
  final RxInt tagIndex = 0.obs;
  List<LiveSecondTag>? newTags;

  final Rx<Pair<LiveCardList?, LiveCardList?>> topState =
      Pair<LiveCardList?, LiveCardList?>(first: null, second: null).obs;

  final followController = ScrollController();

  bool showFirstFrame = false;

  @override
  void checkIsEnd(int length) {
    if (count != null && length >= count!) {
      isEnd = true;
    }
  }

  @override
  List? getDataList(response) {
    return response.cardList;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success response) {
    final result = response.response;
    if (result is LiveIndexData && result.hasMore == 0) isEnd = true;
    if (isRefresh) {
      final res = response.response;
      if (res is LiveIndexData) {
        _topVersion++;
        _filterFollowedRooms(res.followItem);
        topState.value = Pair(
          first: res.followItem,
          second: res.areaItem,
        );
      } else if (res is LiveSecondData) {
        count = res.count;
        newTags = res.newTags;
        if (sortType != null) {
          tagIndex.value =
              newTags?.indexWhere((e) => e.sortType == sortType) ?? -1;
        }
      }
    }
    return false;
  }

  void _filterFollowedRooms(LiveCardList? item) {
    final cardData = item?.cardData?.myIdolV1;
    final list = cardData?.list;
    if (list != null) {
      cardData!.list = filterCandidates(list).cast<CardLiveItem>();
    }
  }

  @override
  Future<LoadingState> customGetData() {
    if (areaIndex.value != 0) {
      return LiveHttp.liveSecondList(
        pn: page,
        areaId: areaId,
        parentAreaId: parentAreaId,
        sortType: sortType,
      );
    }
    return LiveHttp.liveFeedIndex(pn: page);
  }

  @override
  Future<void> onRefresh() {
    count = null;
    page = 1;
    isEnd = false;
    if (areaIndex.value != 0) {
      queryTop().whenComplete(followController.jumpToTop);
      return queryData();
    }
    return queryData().whenComplete(followController.jumpToTop);
  }

  Future<void> queryTop() async {
    if (isClosed) return;
    final context = queryContext;
    final version = ++_topVersion;
    final areaId = this.areaId;
    final parentAreaId = this.parentAreaId;
    final res = await LiveHttp.liveFeedIndex(pn: page, moduleSelect: true);
    if (isClosed ||
        version != _topVersion ||
        !identical(context, queryContext) ||
        areaId != this.areaId ||
        parentAreaId != this.parentAreaId) {
      return;
    }
    if (res case Success(:final response)) {
      _filterFollowedRooms(response.followItem);
      topState.value = Pair(
        first: response.followItem,
        second: response.areaItem,
      );
      final index = response.areaItem?.cardData?.areaEntranceV3?.list
          ?.indexWhere(
            (e) => e.areaV2Id == areaId && e.areaV2ParentId == parentAreaId,
          );
      areaIndex.value = areaId == null
          ? 0
          : index != null && index >= 0
          ? index + 1
          : -1;
    }
  }

  void onSelectArea(int index, CardLiveItem? cardLiveItem) {
    if (isLoading) {
      return; // areaIndex conflict
    }
    if (index == areaIndex.value) {
      return;
    }
    tagIndex.value = 0;
    newTags = null;
    sortType = null;
    areaIndex.value = index;
    areaId = cardLiveItem?.areaV2Id;
    parentAreaId = cardLiveItem?.areaV2ParentId;

    count = null;
    page = 1;
    isEnd = false;
    queryData();
  }

  void onSelectTag(int index, String? sortType) {
    if (isLoading) {
      return;
    }
    tagIndex.value = index;
    this.sortType = sortType;

    count = null;
    page = 1;
    isEnd = false;
    queryData();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    Accounts.recommendChanges.removeListener(_onAccountChanged);
    _topVersion++;
    followController.dispose();
    super.onClose();
  }
}
