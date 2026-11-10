import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/item.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_data_list_item.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/media_author_filter.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

class _Video extends BaseVideoItemModel {
  _Video(int id, int mid, {bool cooperation = false}) {
    aid = id;
    bvid = IdUtils.av2bv(id);
    owner = Owner(mid: mid);
    authors = VideoAuthors(isCooperation: cooperation);
  }
}

class _Feed extends DiscoveryListController<List<Object>, Object> {
  final requests =
      <({int page, Completer<LoadingState<List<Object>>> result})>[];
  int? total;
  bool paginated = true;
  bool neverEnd = false;
  CooperativeAuthors? authorLookup;
  bool recommend = false;
  Completer<void>? preparation;

  @override
  Account get queryAccount =>
      recommend ? Accounts.get(AccountType.recommend) : super.queryAccount;

  @override
  CooperativeAuthors get cooperativeAuthors =>
      authorLookup ?? super.cooperativeAuthors;

  @override
  bool get isEnd => neverEnd ? false : super.isEnd;

  @override
  bool get supportsPagination => paginated;

  @override
  Future<void>? prepareQuery() => preparation?.future;

  @override
  Future<LoadingState<List<Object>>> customGetData() {
    final result = Completer<LoadingState<List<Object>>>();
    requests.add((page: page, result: result));
    return result.future;
  }

  @override
  void checkIsEnd(int length) {
    if (total case final total? when length >= total) isEnd = true;
  }

  Future<void> respond(LoadingState<List<Object>> response) async {
    requests.last.result.complete(response);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = MemoryBox();
  late _Feed feed;
  setUpAll(() {
    GStorage.setting = settings;
    GStorage.localCache = MemoryBox();
  });
  setUp(() {
    settings.data.clear();
    Accounts.accountMode[0] = AnonymousAccount();
    Accounts.accountMode[AccountType.recommend.index] = AnonymousAccount();
    GlobalData().blackMids = {7};
    feed = _Feed();
  });
  tearDown(() => feed.onDelete());

  test('过滤后从下一页补位，去重并保留补位页剩余内容', () async {
    final kept = _Video(1, 8);
    final other = _Video(3, 9);
    final extra = _Video(4, 9);
    final query = feed.onRefresh();
    await feed.respond(Success([kept, _Video(2, 7)]));
    expect(feed.requests.map((r) => r.page), [1, 2]);
    expect(feed.isLoading, isTrue);
    await feed.onLoadMore();
    expect(feed.requests, hasLength(2));
    await feed.respond(Success([kept, other, extra]));
    await query;
    expect(feed.loadingState.value.data, [kept, other, extra]);
    expect(feed.page, 3);
  });

  test('仅补查合作视频，在写入列表前检查全部作者并补位', () async {
    final calls = <String>[];
    final pending = Completer<Set<int>?>();
    feed.authorLookup = CooperativeAuthors(
      load: (bvid) {
        calls.add(bvid);
        return pending.future;
      },
    );
    final cooperation = _Video(1, 8, cooperation: true);
    final ordinary = _Video(2, 8);
    final primaryBlocked = _Video(3, 7, cooperation: true);
    final known = _Video(4, 8, cooperation: true)..authors.mids = {8, 9};
    final query = feed.onRefresh();
    await feed.respond(Success([cooperation, ordinary, primaryBlocked, known]));
    expect(calls, [cooperation.bvid]);
    expect(feed.loadingState.value, isA<Loading>());
    pending.complete({7, 8});
    await Future<void>.delayed(Duration.zero);
    final extra = _Video(5, 9);
    final more = _Video(6, 9);
    await feed.respond(Success([extra, more]));
    await query;
    expect(feed.loadingState.value.data, [ordinary, known, extra, more]);
    expect(feed.requests.map((r) => r.page), [1, 2]);
  });

  test('关闭合作作者检查或黑名单为空时跳过补查', () async {
    var calls = 0;
    feed.authorLookup = CooperativeAuthors(
      load: (_) async {
        calls++;
        return {7};
      },
    );
    final cooperation = _Video(1, 8, cooperation: true)..authors.mids = {7, 8};
    settings.data[SettingBoxKey.checkCooperativeAuthors] = false;
    final disabled = feed.onRefresh();
    await feed.respond(Success([cooperation]));
    await disabled;
    expect(feed.loadingState.value.data, [cooperation]);
    settings.data[SettingBoxKey.checkCooperativeAuthors] = true;
    GlobalData().blackMids = {};
    final empty = feed.onRefresh();
    await feed.respond(Success([_Video(2, 8, cooperation: true)]));
    await empty;
    expect(calls, 0);
  });

  test('合作作者补查期间刷新时丢弃旧批次且不再补位', () async {
    final pending = Completer<Set<int>?>();
    feed.authorLookup = CooperativeAuthors(load: (_) => pending.future);
    final cooperation = _Video(1, 8, cooperation: true);
    final old = feed.onRefresh();
    await feed.respond(Success([cooperation]));
    final current = feed.onRefresh();
    final ordinary = _Video(2, 8);
    await feed.respond(Success([ordinary]));
    await current;
    pending.complete({7, 8});
    await old;
    expect(feed.loadingState.value.data, [ordinary]);
    expect(feed.requests.map((r) => r.page), [1, 1]);
    expect(cooperation.authors.mids, isNull);
  });

  test('合作作者补查失败时保留主投稿者过滤结果', () async {
    feed.authorLookup = CooperativeAuthors(
      load: (_) async => throw StateError('fixture failure'),
    );
    final cooperation = _Video(1, 8, cooperation: true);
    final query = feed.onRefresh();
    await feed.respond(Success([cooperation]));
    await query;
    expect(feed.loadingState.value.data, [cooperation]);
    expect(feed.isLoading, isFalse);
  });

  test('整页被屏蔽时继续取下一页，真实空页才结束', () async {
    final query = feed.onRefresh();
    await feed.respond(Success([_Video(1, 7), _Video(2, 7)]));
    expect(feed.isEnd, isFalse);
    await feed.respond(const Success([]));
    await query;
    expect(feed.loadingState.value.data, isEmpty);
    expect(feed.isEnd, isTrue);
  });

  test('连续命中时每次操作限五页，后续加载从未读页继续', () async {
    final query = feed.onRefresh();
    for (var i = 1; i <= 5; i++) {
      await feed.respond(Success([_Video(i, 7)]));
    }
    await query;
    expect(feed.requests, hasLength(5));
    expect(feed.page, 6);
    expect(feed.isEnd, isFalse);
    final next = feed.onLoadMore();
    await feed.respond(Success([_Video(6, 8)]));
    await next;
    expect(feed.requests.last.page, 6);
    expect(feed.loadingState.value.data, hasLength(1));
  });

  test('来源总数按消费数量判断，过滤不会越过来源终点', () async {
    feed.total = 2;
    final query = feed.onRefresh();
    await feed.respond(Success([_Video(1, 7), _Video(2, 8)]));
    await query;
    expect(feed.isEnd, isTrue);
    expect(feed.requests, hasLength(1));
    expect(feed.loadingState.value.data, hasLength(1));
  });

  test('补位失败保留可见内容和可重试页码', () async {
    final kept = _Video(1, 8);
    final query = feed.onRefresh();
    await feed.respond(Success([kept, _Video(2, 7)]));
    await feed.respond(const Error('补位失败'));
    await query;
    expect(feed.loadingState.value.data, [kept]);
    expect(feed.page, 2);
    expect(feed.isLoading, isFalse);
  });

  test('补位期间刷新隔离旧结果，旧请求不会继续请求下一页', () async {
    final old = feed.onRefresh();
    await feed.respond(Success([_Video(1, 7)]));
    final oldRefill = feed.requests.last.result;
    final current = feed.onRefresh();
    final kept = _Video(3, 8);
    await feed.respond(Success([kept]));
    await current;
    oldRefill.complete(Success([_Video(2, 7)]));
    await old;
    expect(feed.loadingState.value.data, [kept]);
    expect(feed.requests.map((r) => r.page), [1, 2, 1]);
    expect(feed.page, 2);
  });

  test('切换账号后丢弃旧账号的信息流结果', () async {
    final query = feed.onRefresh();
    Accounts.accountMode[0] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'fixture-csrf'}),
      null,
      null,
    );
    await feed.respond(Success([_Video(1, 8)]));
    await query;
    expect(feed.loadingState.value, isA<Loading>());
    expect(feed.page, 1);
  });

  LoginAccount recommendAccount() => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'fixture-csrf'}),
    null,
    null,
  );

  test('同 UID 推荐凭据替换后拒绝旧结果，主账号上下文继续有效', () async {
    feed.recommend = true;
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    final context = feed.queryContext;
    expect(identical(context, feed.queryContext), isTrue);
    final query = feed.onRefresh();
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    await feed.respond(Success([_Video(1, 8)]));
    await query;
    expect(feed.loadingState.value, isA<Loading>());
    expect(feed.page, 1);
    feed.recommend = false;
    final mainContext = feed.queryContext;
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    expect(identical(mainContext, feed.queryContext), isTrue);
  });

  test('屏蔽准备期间推荐账号更换，不发送新账号请求承接旧查询', () async {
    feed
      ..recommend = true
      ..preparation = Completer<void>();
    final query = feed.onRefresh();
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    feed.preparation!.complete();
    await query;
    expect(feed.requests, isEmpty);
  });

  test('合作作者补查期间推荐账号更换，旧批次不发布或继续补页', () async {
    feed.recommend = true;
    final pending = Completer<Set<int>?>();
    feed.authorLookup = CooperativeAuthors(load: (_) => pending.future);
    final query = feed.onRefresh();
    await feed.respond(Success([_Video(1, 8, cooperation: true)]));
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    pending.complete({7, 8});
    await query;
    expect(feed.loadingState.value, isA<Loading>());
    expect(feed.requests, hasLength(1));
  });

  test('切换推荐账号后加载更多从首页重读，避免混入旧账号列表', () async {
    feed.recommend = true;
    final initial = feed.onRefresh();
    await feed.respond(Success([_Video(1, 8)]));
    await initial;
    Accounts.accountMode[AccountType.recommend.index] = recommendAccount();
    final next = feed.onLoadMore();
    expect(feed.loadingState.value, isA<Loading>());
    expect(feed.requests.last.page, 1);
    final replacement = _Video(2, 8);
    await feed.respond(Success([replacement]));
    await next;
    expect(feed.loadingState.value.data, [replacement]);
  });

  test('推荐流即使永不标记终点，空响应也结束当前补位', () async {
    feed.neverEnd = true;
    final query = feed.onRefresh();
    await feed.respond(Success([_Video(1, 7)]));
    await feed.respond(const Success([]));
    await query;
    expect(feed.requests, hasLength(2));
    expect(feed.page, 2);
  });

  test('关闭开关后保留原始内容且不补位', () async {
    settings.data[SettingBoxKey.filterBlockedAuthors] = false;
    final blocked = _Video(1, 7);
    final query = feed.onRefresh();
    await feed.respond(Success([blocked]));
    await query;
    expect(feed.loadingState.value.data, [blocked]);
    expect(feed.requests, hasLength(1));
  });

  test('固定列表过滤后保持来源范围', () async {
    feed.paginated = false;
    final query = feed.onRefresh();
    await feed.respond(Success([_Video(1, 7)]));
    await query;
    expect(feed.loadingState.value.data, isEmpty);
    expect(feed.requests, hasLength(1));
    expect(feed.canLoadMore, isFalse);
  });

  test('保留上次推荐时同样屏蔽历史推荐中的拉黑作者', () {
    final controller = RcmdController()..page = 0;
    final kept = _Video(1, 8);
    controller.loadingState.value = Success([kept, _Video(2, 7)]);
    controller.applyResponse(true, Success([_Video(3, 7)]));
    expect(controller.loadingState.value.data, [kept]);
    controller.onDelete();
  });

  test('专栏、直播和转发的原作者沿统一规则判定', () {
    final dynamicItem = DynamicItemModel.fromJson({
      'id_str': '1',
      'modules': <String, dynamic>{},
      'orig': {
        'modules': {
          'module_author': {'mid': 7},
        },
      },
    });
    final cards = <Object>[
      SearchArticleItemModel(mid: 7, id: 1, title: []),
      SearchLiveItemModel(uid: 7, title: []),
      CardLiveItem(uid: 7),
      TopicCardItem(dynamicCardItem: dynamicItem),
    ];
    for (final card in cards) {
      expect(MediaAuthorFilter.isBlocked(card, (mid) => mid == 7), isTrue);
    }
    expect(
      MediaAuthorFilter.isBlocked(CardLiveItem(), (mid) => mid == 7),
      isFalse,
    );
  });
}
