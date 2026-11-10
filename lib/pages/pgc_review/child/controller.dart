import 'dart:math' show max;

import 'package:collection/collection.dart';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/models/common/pgc_review_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_review/data.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_review/list.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_review/stat.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class PgcReviewController
    extends CommonListController<PgcReviewData, PgcReviewItemModel> {
  PgcReviewController({required this.type, required this.mediaId});

  final PgcReviewType type;
  final Object? mediaId;

  @override
  Object get queryContext => Accounts.main;

  final pendingReviews = <int>{}.obs;

  final count = RxnInt();
  String? next;
  final sortType = PgcReviewSortType.def.obs;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    count.value = null;
    onReload();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  Future<void> onRefresh() {
    next = null;
    return super.onRefresh();
  }

  @override
  void checkIsEnd(int length) {
    final count = this.count.value;
    if (count != null && length >= count) {
      isEnd = true;
    }
  }

  @override
  List<PgcReviewItemModel>? getDataList(PgcReviewData response) {
    if (type == PgcReviewType.long &&
        sortType.value == PgcReviewSortType.latest) {
      count.value = null;
    } else {
      count.value = response.count;
    }
    if (response.next == null ||
        response.next!.isEmpty ||
        response.next == next) {
      isEnd = true;
    }
    next = response.next;

    return response.list;
  }

  @override
  Future<LoadingState<PgcReviewData>> customGetData() => PgcHttp.pgcReview(
    type: type,
    mediaId: mediaId,
    next: next,
    sort: sortType.value.sort,
    account: Accounts.main,
  );

  @override
  List<PgcReviewItemModel> filterList(
    List<PgcReviewItemModel> source,
    bool isRefresh,
  ) {
    final seen = <int>{
      if (!isRefresh)
        for (final item in loadingState.value.dataOrNull ?? []) ?item.reviewId,
    };
    return [
      for (final item in source)
        if (item.reviewId == null || seen.add(item.reviewId!)) item,
    ];
  }

  Future<void> _write(
    PgcReviewItemModel item,
    Future<LoadingState<void>> Function() request,
    void Function() apply,
  ) async {
    final id = item.reviewId;
    final list = loadingState.value.dataOrNull;
    if (id == null || id <= 0 || isClosed || list?.contains(item) != true) {
      return;
    }
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (!pendingReviews.add(id)) return;
    try {
      final result = await request();
      if (isClosed ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull) ||
          !list!.contains(item)) {
        return;
      }
      if (result.isSuccess) {
        apply();
        loadingState.refresh();
      } else {
        result.toast();
      }
    } finally {
      pendingReviews.remove(id);
    }
  }

  Future<void> onLike(PgcReviewItemModel item) {
    final account = Accounts.main;
    final liked = item.stat?.liked == 1;
    return _write(
      item,
      () => PgcHttp.pgcReviewLike(
        mediaId: mediaId,
        reviewId: item.reviewId!,
        account: account,
      ),
      () {
        final stat = item.stat ??= Stat();
        if (stat.likes case final likes?) {
          stat.likes = max(0, likes + (liked ? -1 : 1));
        }
        stat.liked = liked ? 0 : 1;
        if (!liked) {
          stat.disliked = 0;
        }
      },
    );
  }

  Future<void> onDislike(PgcReviewItemModel item) {
    final account = Accounts.main;
    final disliked = item.stat?.disliked == 1;
    return _write(
      item,
      () => PgcHttp.pgcReviewDislike(
        mediaId: mediaId,
        reviewId: item.reviewId!,
        account: account,
      ),
      () {
        final stat = (item.stat ??= Stat())..disliked = disliked ? 0 : 1;
        if (!disliked) {
          if (stat.liked == 1) {
            if (stat.likes case final likes?) stat.likes = max(0, likes - 1);
          }
          stat.liked = 0;
        }
      },
    );
  }

  Future<void> onDel(int reviewId) async {
    final item = loadingState.value.dataOrNull?.firstWhereOrNull(
      (item) => item.reviewId == reviewId,
    );
    if (item == null) return;
    final account = Accounts.main;
    await _write(
      item,
      () => PgcHttp.pgcReviewDel(
        mediaId: mediaId,
        reviewId: reviewId,
        account: account,
      ),
      () {
        loadingState.value.data!.removeWhere(
          (item) => item.reviewId == reviewId,
        );
        if (count.value case final value? when value > 0) {
          count.value = value - 1;
        }
        SmartDialog.showToast('删除成功');
      },
    );
  }

  void queryBySort() {
    if (isLoading) return;
    sortType.value = sortType.value == PgcReviewSortType.def
        ? PgcReviewSortType.latest
        : PgcReviewSortType.def;
    onReload();
  }
}
