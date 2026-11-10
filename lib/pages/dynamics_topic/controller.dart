import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/item.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/topic_card_list.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/topic_sort_by_conf.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/top_details.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/topic_item.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DynTopicController
    extends DiscoveryListController<TopicCardList?, TopicCardItem> {
  final topicId = Get.parameters['id']!;
  String topicName = Get.parameters['name'] ?? '';

  int sortBy = 0;
  String? offset;
  final topicSortByConf = Rxn<TopicSortByConf>();

  double? appbarOffset;

  // top
  final isFav = false.obs;
  final isLike = false.obs;
  Rx<LoadingState<TopDetails?>> topState =
      LoadingState<TopDetails?>.loading().obs;

  bool get isLogin => Accounts.main.isLogin;
  int _topVersion = 0;
  bool _savingFav = false;
  bool _savingLike = false;
  List<TopicCardItem>? _foldingList;
  Account _contextMain = Accounts.main;
  Account _contextRecommend = Accounts.get(AccountType.recommend);
  Object _queryContext = Object();

  @override
  Object get queryContext {
    final main = Accounts.main;
    final recommend = Accounts.get(AccountType.recommend);
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
    queryTop();
    queryData();
  }

  void _onAccountChanged() {
    final previous = _queryContext;
    if (identical(previous, queryContext)) return;
    isFav.value = false;
    isLike.value = false;
    topState.value = LoadingState<TopDetails?>.loading();
    onReload();
  }

  Future<void> queryTop() async {
    final account = Accounts.main;
    final version = ++_topVersion;
    final result = await DynamicsHttp.topicTop(
      account: account,
      topicId: topicId,
    );
    if (isClosed ||
        version != _topVersion ||
        !identical(account, Accounts.main)) {
      return;
    }
    if (result case Success(:final response)) {
      final item = response?.topicItem;
      if (response != null && item == null) {
        topState.value = const Error('话题信息不完整，请重试');
        return;
      }
      topState.value = result;
      if (item != null) topicName = item.name;
      isFav.value = item?.isFav ?? false;
      isLike.value = item?.isLike ?? false;
    } else {
      topState.value = result;
    }
  }

  @override
  List<TopicCardItem>? getDataList(TopicCardList? response) {
    if (response != null) {
      if (offset != null && response.offset == offset) isEnd = true;
      offset = response.offset;
      topicSortByConf.value = response.topicSortByConf;
      sortBy = response.topicSortByConf?.showSortBy ?? 0;
      if (response.hasMore == false) {
        isEnd = true;
      }
      return response.items;
    }
    return null;
  }

  @override
  Future<void> onRefresh() {
    offset = '';
    queryTop();
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    if (appbarOffset != null) {
      if (scrollController.hasClients &&
          scrollController.offset > appbarOffset!) {
        scrollController.jumpTo(appbarOffset!);
      }
    } else {
      scrollController.jumpToTop();
    }
    return super.onReload();
  }

  @override
  Future<LoadingState<TopicCardList?>> customGetData() =>
      DynamicsHttp.topicFeed(
        account: Accounts.get(AccountType.recommend),
        topicId: topicId,
        offset: offset,
        sortBy: sortBy,
      );

  void onSort(int sortBy) {
    this.sortBy = sortBy;
    onReload();
  }

  Future<void> onFav() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final item = topState.value.dataOrNull?.topicItem;
    if (_savingFav || item == null || isClosed) return;
    final account = Accounts.main;
    final wasFav = isFav.value;
    _savingFav = true;
    _topVersion++;
    try {
      final res = wasFav
          ? await FavHttp.delFavTopic(topicId, account: account)
          : await FavHttp.addFavTopic(topicId, account: account);
      if (!_ownsTop(account, item)) return;
      if (res.isSuccess) {
        if (!wasFav) {
          item.fav++;
        } else if (item.fav > 0) {
          item.fav--;
        }
        isFav.value = !wasFav;
        item.isFav = !wasFav;
        topState.refresh();
      } else {
        res.toast();
      }
    } finally {
      _savingFav = false;
    }
  }

  Future<void> onLike() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final item = topState.value.dataOrNull?.topicItem;
    if (_savingLike || item == null || isClosed) return;
    final account = Accounts.main;
    final wasLike = isLike.value;
    _savingLike = true;
    _topVersion++;
    try {
      final res = await FavHttp.likeTopic(topicId, wasLike);
      if (!_ownsTop(account, item)) return;
      if (res.isSuccess) {
        if (!wasLike) {
          item.like++;
        } else if (item.like > 0) {
          item.like--;
        }
        isLike.value = !wasLike;
        item.isLike = !wasLike;
        topState.refresh();
      } else {
        res.toast();
      }
    } finally {
      _savingLike = false;
    }
  }

  bool _ownsTop(Account account, TopicItem item) =>
      !isClosed &&
      identical(account, Accounts.main) &&
      identical(item, topState.value.dataOrNull?.topicItem);

  Future<void> topicFold() async {
    final list = loadingState.value.dataOrNull;
    final fold = list?.where((item) => item.foldCardItem != null).firstOrNull;
    if (isClosed ||
        isLoading ||
        list == null ||
        fold == null ||
        identical(list, _foldingList)) {
      return;
    }
    final context = queryContext;
    final sort = sortBy;
    _foldingList = list;
    try {
      final res = await DynamicsHttp.topicFold(
        account: Accounts.get(AccountType.recommend),
        topicId: topicId,
        sortBy: sort,
      );
      if (isClosed ||
          isLoading ||
          !identical(context, queryContext) ||
          !identical(list, loadingState.value.dataOrNull) ||
          sort != sortBy ||
          !list.contains(fold)) {
        return;
      }
      if (res case Success(:final response)) {
        if (response?.items case final items? when items.isNotEmpty) {
          final index = list.indexOf(fold);
          final additions = filterCandidates(items, existing: list);
          list
            ..removeAt(index)
            ..insertAll(index, additions);
          loadingState.refresh();
        }
      } else {
        res.toast();
      }
    } finally {
      if (identical(_foldingList, list)) _foldingList = null;
    }
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    Accounts.recommendChanges.removeListener(_onAccountChanged);
    _topVersion++;
    super.onClose();
  }
}
