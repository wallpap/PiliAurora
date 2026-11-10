import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/services/blocked_authors.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/media_author_filter.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 发现类内容在进入页面状态前过滤，并沿原来源补足当前批次。
abstract class DiscoveryListController<R, T>
    extends CommonListController<R, T> {
  bool get supportsPagination => true;

  @override
  bool get canLoadMore => supportsPagination && super.canLoadMore;

  @override
  bool get refillFilteredPages =>
      supportsPagination && Pref.filterBlockedAuthors;

  Account get queryAccount => Accounts.main;

  Account? _contextMain;
  Account? _contextQuery;
  Object _context = Object();
  Object? _listContext;

  @override
  Object get queryContext {
    final main = Accounts.main;
    final query = queryAccount;
    // 屏蔽规则属于主账号，内容请求可使用独立推荐账号。
    if (!identical(main, _contextMain) || !identical(query, _contextQuery)) {
      _contextMain = main;
      _contextQuery = query;
      _context = Object();
    }
    return _context;
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    final context = queryContext;
    if (!isRefresh && !identical(_listContext, context)) {
      return onReload();
    }
    _listContext = context;
    return super.queryData(isRefresh);
  }

  @override
  Future<void>? prepareQuery() => BlockedAuthors.ensureLoaded();

  CooperativeAuthors get cooperativeAuthors => CooperativeAuthors.shared;

  @override
  Future<void>? prepareResponse(R response, bool Function() isCurrent) {
    if (!Pref.filterBlockedAuthors ||
        !Pref.checkCooperativeAuthors ||
        GlobalData().blackMids.isEmpty) {
      return null;
    }
    final videos =
        [
              ...MediaAuthorFilter.videos(response),
              ...MediaAuthorFilter.videos(loadingState.value.dataOrNull),
            ]
            .where(
              (video) =>
                  video.authors.isCooperation &&
                  video.authors.mids == null &&
                  !BlockedAuthors.contains(video.ownerMid),
            )
            .toList();
    return videos.isEmpty
        ? null
        : cooperativeAuthors.prepare(videos, isCurrent: isCurrent);
  }

  List<T> filterCandidates(
    Iterable<T> source, {
    Iterable<T> existing = const [],
  }) {
    if (!Pref.filterBlockedAuthors) return source.toList();
    final seen = existing
        .map(MediaAuthorFilter.contentKey)
        .whereType<Object>()
        .toSet();
    return source.where((item) {
      if (MediaAuthorFilter.isBlocked(
        item,
        BlockedAuthors.contains,
        includeCoauthors: Pref.checkCooperativeAuthors,
      )) {
        return false;
      }
      final key = MediaAuthorFilter.contentKey(item);
      return key == null || seen.add(key);
    }).toList();
  }

  @override
  List<T> filterList(List<T> source, bool isRefresh) => filterCandidates(
    source,
    existing: isRefresh ? const [] : loadingState.value.dataOrNull ?? const [],
  );
}
