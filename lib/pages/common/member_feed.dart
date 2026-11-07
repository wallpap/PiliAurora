import 'package:pili_aurora/models/common/member/contribute_type.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/remote/member_guard/guard_top_list.dart';
import 'package:pili_aurora/models/remote/space/space_shop/data.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

enum MemberFeedKind {
  article,
  audio,
  coin,
  like,
  shop,
  guard,
  cheese,
  comic,
  series,
}

typedef MemberFeedQuery = ({MemberFeedKind kind, String mid, Object owner});
final memberFeedProvider = AsyncNotifierProvider.autoDispose
    .family<MemberFeedNotifier, MemberFeedState, MemberFeedQuery>(
      MemberFeedNotifier.new,
      retry: (_, _) => null,
    );

class MemberFeedState {
  MemberFeedState({
    required Iterable<dynamic> items,
    required this.nextPage,
    required this.hasMore,
    this.total,
    Iterable<GuardItem> tops = const [],
    this.shop,
    this.loadingMore = false,
    this.error,
    Object? source,
  }) : items = List.unmodifiable(items),
       tops = List.unmodifiable(tops),
       source = source ?? Object();
  final List<dynamic> items;
  final List<GuardItem> tops;
  final SpaceShopData? shop;
  final int nextPage;
  final bool hasMore;
  final int? total;
  final bool loadingMore;
  final String? error;
  final Object source;
  bool get canLoadMore => hasMore && !loadingMore && error == null;
  MemberFeedState operation({bool loadingMore = false, String? error}) =>
      MemberFeedState(
        items: items,
        nextPage: nextPage,
        hasMore: hasMore,
        total: total,
        tops: tops,
        shop: shop,
        loadingMore: loadingMore,
        error: error,
        source: source,
      );
}

class MemberFeedNotifier extends AsyncNotifier<MemberFeedState> {
  MemberFeedNotifier(this.query);
  final MemberFeedQuery query;
  @override
  Future<MemberFeedState> build() =>
      _page(ref.watch(mainAccountProvider), null);
  Future<MemberFeedState> _page(
    Account account,
    MemberFeedState? before,
  ) async {
    final page = before?.nextPage ?? 1;
    final mid = int.parse(query.mid);
    List<dynamic> rows;
    int? total;
    bool more;
    SpaceShopData? shop;
    final tops = <GuardItem>[...?before?.tops];
    switch (query.kind) {
      case MemberFeedKind.article:
        final data = (await MemberHttp.spaceArticle(
          account: account,
          mid: mid,
          page: page,
        )).data;
        rows = data.item ?? [];
        total = data.count;
        more =
            rows.isNotEmpty &&
            (total == null ? rows.length >= 10 : page * 10 < total);
      case MemberFeedKind.audio:
        final data = (await MemberHttp.spaceAudio(
          account: account,
          mid: mid,
          page: page,
        )).data;
        rows = data.items ?? [];
        total = data.totalSize;
        more =
            rows.isNotEmpty &&
            (total == null ? rows.length >= 20 : page * 20 < total);
      case MemberFeedKind.coin || MemberFeedKind.like:
        final data =
            (await (query.kind == MemberFeedKind.coin
                    ? MemberHttp.coinArc(account: account, mid: mid, page: page)
                    : MemberHttp.likeArc(
                        account: account,
                        mid: mid,
                        page: page,
                      )))
                .data;
        rows = data.item ?? [];
        total = data.count;
        more =
            rows.isNotEmpty &&
            (total == null ? rows.length >= 20 : page * 20 < total);
      case MemberFeedKind.cheese:
        final data = (await MemberHttp.spaceCheese(
          account: account,
          mid: mid,
          page: page,
        )).data;
        rows = data.items ?? [];
        more = rows.isNotEmpty && (data.page?.next ?? rows.length >= 30);
      case MemberFeedKind.comic:
        final data = (await MemberHttp.spaceArchive(
          account: account,
          type: ContributeType.comic,
          mid: mid,
          pn: page,
        )).data;
        rows = data.item ?? [];
        total = data.count;
        more =
            rows.isNotEmpty &&
            (data.hasNext ??
                (total == null ? rows.length >= 20 : page * 20 < total));
      case MemberFeedKind.series:
        final data = (await MemberHttp.seasonSeriesList(
          account: account,
          mid: mid,
          pn: page,
        )).data;
        rows = [...?data.seasonsList, ...?data.seriesList];
        total = data.page?.total;
        more =
            rows.isNotEmpty &&
            (total == null ? rows.length >= 10 : page * 10 < total);
      case MemberFeedKind.shop:
        // 商品接口没有可用的后续游标，完整商品入口由服务端 clickUrl 提供。
        shop = (await MemberHttp.spaceShop(account: account, mid: mid)).data;
        rows = shop.data ?? [];
        more = false;
      case MemberFeedKind.guard:
        final data = (await MemberHttp.memberGuard(
          account: account,
          ruid: mid,
          page: page,
        )).data;
        rows = data.guardTopList;
        more = data.hasMore == 1 && rows.isNotEmpty;
        if (before == null) {
          tops.addAll(rows.take(3).cast<GuardItem>());
          rows = rows.skip(3).toList();
        }
    }
    Object identity(dynamic row) => switch (query.kind) {
      MemberFeedKind.article => row.uri ?? row,
      MemberFeedKind.audio => row.id ?? row,
      MemberFeedKind.coin || MemberFeedKind.like => row.param ?? row.uri ?? row,
      MemberFeedKind.shop => row.cardUrl ?? row,
      MemberFeedKind.guard => row.uid,
      MemberFeedKind.cheese => row.seasonId ?? row,
      MemberFeedKind.comic => row.param ?? row.uri ?? row,
      MemberFeedKind.series =>
        row.meta?.seasonId != null
            ? ('season', row.meta.seasonId)
            : row.meta?.seriesId != null
            ? ('series', row.meta.seriesId)
            : row,
    };
    final seen = <Object>{for (final item in tops) item.uid};
    final items = [
      for (final item in [...?before?.items, ...rows])
        if (seen.add(identity(item))) item,
    ];
    if (before != null && items.length == before.items.length) more = false;
    return MemberFeedState(
      items: items,
      tops: tops,
      shop: shop,
      total: total,
      nextPage: page + 1,
      hasMore: more,
      source: before?.source,
    );
  }

  Future<void> loadMore({bool retry = false}) async {
    final before = state.value;
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        !before.hasMore ||
        before.loadingMore ||
        (!retry && before.error != null)) {
      return;
    }
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (!identical(account, Accounts.main)) return;
    state = AsyncData(before.operation(loadingMore: true));
    try {
      final result = await _page(account, before);
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(result);
      }
    } catch (_) {
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(before.operation(error: '加载失败，点击重试'));
      }
    }
  }
}
