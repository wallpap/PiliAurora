import 'package:collection/collection.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/list.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_result/list.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_timeline/result.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

class PgcController
    extends CommonListController<List<PgcIndexItem>?, PgcIndexItem> {
  PgcController({required this.tabType})
    : indexType = tabType == HomeTabType.cinema ? 102 : null;

  final HomeTabType tabType;
  final int? indexType;

  late final showPgcTimeline =
      tabType == HomeTabType.bangumi && Pref.showPgcTimeline;

  final accountService = Get.find<AccountService>();

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onMainChanged);
    Accounts.recommendChanges.addListener(_onRecommendChanged);
    queryData();
    queryPgcFollow();
    if (showPgcTimeline) {
      queryPgcTimeline();
    }
  }

  @override
  Object get queryContext => Accounts.get(AccountType.recommend);

  void _onRecommendChanged() {
    loadingState.value = LoadingState.loading();
    page = 1;
    isEnd = false;
    queryData();
  }

  void _onMainChanged() {
    onChangeAccount(Accounts.main.isLogin);
    if (showPgcTimeline) queryPgcTimeline();
  }

  @override
  Future<void> onRefresh() async {
    await Future.wait([
      super.onRefresh(),
      if (Accounts.main.isLogin) queryPgcFollow(),
      if (showPgcTimeline) queryPgcTimeline(),
    ]);
  }

  int _followGeneration = 0;
  int _timelineVersion = 0;
  final timelineWarning = RxnString();

  // follow
  late int followPage = 1;
  late RxInt followCount = (-1).obs;
  late bool followLoading = false;
  late bool followEnd = false;
  late Rx<LoadingState<List<FavPgcItemModel>?>> followState =
      LoadingState<List<FavPgcItemModel>?>.loading().obs;
  final followController = ScrollController();

  // timeline
  late Rx<LoadingState<List<TimelineResult>?>> timelineState =
      LoadingState<List<TimelineResult>?>.loading().obs;

  Future<void> queryPgcTimeline() async {
    if (isClosed) return;
    final version = ++_timelineVersion;
    final account = Accounts.main;
    final results = await Future.wait([
      PgcHttp.pgcTimeline(types: 1, before: 6, after: 6, account: account),
      PgcHttp.pgcTimeline(types: 4, before: 6, after: 6, account: account),
    ]);
    if (isClosed ||
        version != _timelineVersion ||
        !identical(account, Accounts.main)) {
      return;
    }
    final days = <TimelineResult>[];
    Error? failure;
    for (final result in results) {
      if (result case Error error) {
        failure ??= error;
        continue;
      }
      for (final day in result.data ?? <TimelineResult>[]) {
        final existing = days.firstWhereOrNull(
          (other) => day.dateTs != null
              ? other.dateTs == day.dateTs
              : day.date != null && other.date == day.date,
        );
        if (existing == null) {
          days.add(
            TimelineResult(
              date: day.date,
              dateTs: day.dateTs,
              dayOfWeek: day.dayOfWeek,
              episodes: day.episodes == null ? null : List.of(day.episodes!),
              isToday: day.isToday,
            ),
          );
        } else {
          if (day.episodes case final episodes?) {
            (existing.episodes ??= []).addAll(episodes);
          }
        }
      }
    }
    days.sort((a, b) => (a.dateTs ?? 0).compareTo(b.dateTs ?? 0));
    timelineWarning.value = failure != null && days.isNotEmpty
        ? '部分时间表加载失败，点击重试'
        : null;
    timelineState.value = failure != null && days.isEmpty
        ? failure
        : Success(days);
  }

  // 我的订阅
  Future<void> queryPgcFollow([bool isRefresh = true]) async {
    if (!Accounts.main.isLogin ||
        (!isRefresh && (followLoading || followEnd))) {
      return;
    }
    if (isClosed) return;
    if (isRefresh) {
      _followGeneration++;
      followPage = 1;
      followEnd = false;
    }
    final generation = _followGeneration;
    final account = Accounts.main;
    followLoading = true;
    try {
      final res = await FavHttp.favPgc(
        type: tabType == HomeTabType.bangumi ? 1 : 2,
        pn: followPage,
        account: account,
      );

      if (isClosed ||
          generation != _followGeneration ||
          !identical(account, Accounts.main)) {
        return;
      }
      if (res case Success(:final response)) {
        final list = response.list;
        followCount.value = response.total ?? -1;

        if (list == null || list.isEmpty) {
          followEnd = true;
          if (isRefresh) {
            followState.value = Success(list);
          }
          return;
        }

        if (isRefresh) {
          if (followCount.value >= 0 && list.length >= followCount.value) {
            followEnd = true;
          }
          followState.value = Success(list);
          followController.jumpToTop();
        } else if (followState.value case Success(:final response)) {
          final currentList = response!;
          final seen = currentList.map((item) => item.seasonId ?? item).toSet();
          final additions = list.where(
            (item) => seen.add(item.seasonId ?? item),
          );
          final before = currentList.length;
          currentList.addAll(additions);
          if (currentList.length == before ||
              (followCount.value >= 0 &&
                  currentList.length >= followCount.value)) {
            followEnd = true;
          }
          followState.refresh();
        }
        followPage++;
      } else if (isRefresh) {
        followState.value = res as Error;
      }
    } finally {
      if (generation == _followGeneration) followLoading = false;
    }
  }

  @override
  Future<LoadingState<List<PgcIndexItem>?>> customGetData() => PgcHttp.pgcIndex(
    page: page,
    indexType: indexType,
    account: Accounts.get(AccountType.recommend),
  );

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onMainChanged);
    Accounts.recommendChanges.removeListener(_onRecommendChanged);
    _followGeneration++;
    _timelineVersion++;
    followController.dispose();
    super.onClose();
  }

  void onChangeAccount(bool isLogin) {
    _followGeneration++;
    followLoading = false;
    followState.value = LoadingState.loading();
    followCount.value = -1;
    if (isLogin) {
      queryPgcFollow();
    } else {
      followState.value = LoadingState.loading();
    }
  }
}
