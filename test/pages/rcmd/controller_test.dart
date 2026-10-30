import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/widgets/video_card/video_card_v.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/model_rec_video_item.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/rcmd/view.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Video extends BaseRcmdVideoItemModel {
  _Video(int id, {bool cooperation = false, int mid = 8}) {
    aid = id;
    bvid = IdUtils.av2bv(id);
    title = '视频 $id';
    owner = Owner(mid: mid, name: '作者');
    stat = Stat.fromJson({});
    authors = VideoAuthors(isCooperation: cooperation);
  }
}

class _Box<T> implements Box<T> {
  final entries = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => entries[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async => entries[key] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Feed extends RcmdController {
  Object account = Object();
  Completer<void>? preparation;
  CooperativeAuthors? lookup;
  final requests = <Completer<LoadingState<List<dynamic>>>>[];
  final indices = <int>[];
  final sizes = <int>[];
  final tokens = <CancelToken>[];
  @override
  Object get queryContext => account;
  @override
  Future<void>? prepareQuery() => preparation?.future;
  @override
  CooperativeAuthors get cooperativeAuthors =>
      lookup ?? super.cooperativeAuthors;
  @override
  Future<LoadingState<List<dynamic>>> fetchRecommendations({
    required int index,
    required int pageSize,
    required CancelToken cancelToken,
  }) {
    final result = Completer<LoadingState<List<dynamic>>>();
    indices.add(index);
    sizes.add(pageSize);
    tokens.add(cancelToken);
    requests.add(result);
    return result.future;
  }
}

class _TimedFeed extends _Feed {
  _TimedFeed(this.now);
  final Duration Function() now;
  final starts = <({int index, int milliseconds})>[];
  @override
  Future<void> prepareQuery() =>
      Future<void>.delayed(const Duration(seconds: 2));
  @override
  Future<LoadingState<List<dynamic>>> fetchRecommendations({
    required int index,
    required int pageSize,
    required CancelToken cancelToken,
  }) async {
    starts.add((index: index, milliseconds: now().inMilliseconds));
    await Future<void>.delayed(const Duration(seconds: 1));
    return Success(
      List.generate(10, (i) => _Video(index * 10 + i + 1, cooperation: i == 0)),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = _Box();
  late _Feed feed;
  setUpAll(() {
    GStorage.setting = settings;
    GStorage.localCache = _Box();
    GStorage.userInfo = _Box<UserInfoData>();
  });
  setUp(() {
    settings.entries
      ..clear()
      ..[SettingBoxKey.enableSaveLastData] = false;
    GlobalData().blackMids = {7};
    feed = _Feed();
  });
  tearDown(() {
    feed.onDelete();
    if (feed.preparation case final preparation?
        when !preparation.isCompleted) {
      preparation.complete();
    }
    for (final request in feed.requests) {
      if (!request.isCompleted) request.complete(const Success([]));
    }
  });

  testWidgets('推荐下载与黑名单同步重叠，完成屏蔽准备前不发布', (tester) async {
    feed.preparation = Completer<void>();
    final query = feed.onRefresh();
    await tester.pump();
    expect(feed.requests, hasLength(1));
    feed.requests.single.complete(Success([_Video(1)]));
    await tester.pump();
    expect(feed.loadingState.value, isA<Loading>());
    feed.preparation!.complete();
    await tester.pump();
    await query;
    expect(feed.loadingState.value.data, hasLength(1));
  });

  testWidgets('普通卡片先发布，合作卡片检查后再显示', (tester) async {
    final authors = Completer<Set<int>?>();
    feed.lookup = CooperativeAuthors(load: (_) => authors.future);
    addTearDown(() {
      if (!authors.isCompleted) authors.complete({8});
    });
    final query = feed.onRefresh();
    final ordinary = _Video(1);
    final cooperation = _Video(2, cooperation: true);
    feed.requests.single.complete(Success([cooperation, ordinary]));
    await tester.pump();
    expect(feed.loadingState.value, isA<Success>());
    expect(feed.loadingState.value.data, [cooperation, ordinary]);
    expect(feed.isPending(cooperation), isTrue);
    expect(feed.isPending(ordinary), isFalse);
    authors.complete({7, 8});
    await tester.pump();
    await query;
    expect(feed.loadingState.value.data, [ordinary]);
  });

  testWidgets('App 连续补足视口，无需逐页等待新一帧布局', (tester) async {
    feed.updateViewport(itemCount: 48, columns: 8, active: true);
    for (var index = 0; index < 5; index++) {
      expect(feed.requests, hasLength(index + 1));
      expect(feed.isLoading, isTrue);
      feed.requests[index].complete(
        Success(
          List.generate(
            10,
            (i) => _Video(index * 10 + i + 1),
          ),
        ),
      );
      await tester.idle();
    }
    expect(feed.indices, [0, 1, 2, 3, 4]);
    expect(feed.loadingState.value.data, hasLength(50));
    expect(feed.isLoading, isFalse);
    // 同尺寸重建不增加请求；扩大视口后继续读取未读页。
    feed.updateViewport(itemCount: 48, columns: 8, active: true);
    await tester.idle();
    expect(feed.requests, hasLength(5));
    feed.updateViewport(itemCount: 64, columns: 8, active: true);
    expect(feed.indices.last, 5);
  });

  testWidgets('Web 视口首包与两页下载并发，乱序返回仍按页合并并去重', (tester) async {
    settings.entries[SettingBoxKey.appRcmd] = false;
    settings.entries[SettingBoxKey.filterBlockedAuthors] = false;
    feed.updateViewport(itemCount: 40, columns: 8, active: true);
    expect(feed.sizes.single, 40);
    feed.requests[0].complete(Success(List.generate(10, (i) => _Video(i + 1))));
    await tester.idle();
    expect(feed.indices, [0, 1, 2]);
    feed.requests[2].complete(Success([_Video(11), _Video(13)]));
    await tester.idle();
    expect(feed.loadingState.value.data, hasLength(10));
    feed.requests[1].complete(Success([_Video(11), _Video(12)]));
    await tester.idle();
    expect(feed.loadingState.value.data!.map((item) => (item as _Video).aid), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
    ]);
    // 第 1、2 页合并后才推进窗口，始终最多两个在途请求。
    expect(feed.indices, [0, 1, 2, 3, 4]);
  });

  testWidgets('下一页下载与合作作者检查重叠，拦截后继续补位', (tester) async {
    final authors = Completer<Set<int>?>();
    feed.lookup = CooperativeAuthors(load: (_) => authors.future);
    addTearDown(() {
      if (!authors.isCompleted) authors.complete({8});
    });
    feed.updateViewport(itemCount: 3, columns: 1, active: true);
    final cooperation = _Video(1, cooperation: true);
    feed.requests[0].complete(Success([cooperation, _Video(2)]));
    await tester.idle();
    expect(feed.indices, [0, 1]);
    expect(feed.isPending(cooperation), isTrue);
    feed.requests[1].complete(Success([_Video(3)]));
    await tester.idle();
    expect(feed.requests, hasLength(2));
    authors.complete({7, 8});
    await tester.idle();
    expect(feed.indices, [0, 1, 2]);
    expect(feed.loadingState.value.data, hasLength(2));
    feed.requests[2].complete(Success([_Video(4)]));
    await tester.idle();
    expect(feed.loadingState.value.data!.map((v) => (v as _Video).aid), [
      2,
      3,
      4,
    ]);
  });

  testWidgets('合作卡片逐条揭示，保留原位置且不等待其他卡片', (tester) async {
    final checks = <String, Completer<Set<int>?>>{};
    feed.lookup = CooperativeAuthors(
      load: (bvid) => (checks[bvid] = Completer<Set<int>?>()).future,
    );
    addTearDown(() {
      for (final check in checks.values) {
        if (!check.isCompleted) check.complete(null);
      }
    });
    final query = feed.onRefresh();
    final first = _Video(1, cooperation: true);
    final second = _Video(2, cooperation: true);
    feed.requests.single.complete(Success([first, second, _Video(3)]));
    await tester.idle();
    checks[second.bvid]!.complete({8});
    await tester.idle();
    expect(feed.isPending(first), isTrue);
    expect(feed.isPending(second), isFalse);
    expect(feed.loadingState.value.data!.take(2), [first, second]);
    checks[first.bvid]!.complete(null);
    await tester.idle();
    await query;
    expect(feed.isPending(first), isFalse);
    expect(feed.loadingState.value.data, hasLength(3));
  });

  testWidgets('刷新取消旧下载，晚到结果不修改数据或释放新请求状态', (tester) async {
    final old = feed.onRefresh();
    final refresh = feed.onRefresh();
    expect(feed.tokens[0].isCancelled, isTrue);
    feed.requests[0].complete(Success([_Video(1)]));
    await tester.idle();
    await old;
    expect(feed.isLoading, isTrue);
    expect(feed.loadingState.value, isA<Loading>());
    feed.requests[1].complete(Success([_Video(2)]));
    await tester.idle();
    await refresh;
    expect((feed.loadingState.value.data!.single as _Video).aid, 2);
  });

  for (final changeSource in [false, true]) {
    testWidgets('${changeSource ? '推荐来源' : '主账号'}切换重新初始化，不保留旧内容', (
      tester,
    ) async {
      feed.enableSaveLastData = true;
      var query = feed.onRefresh();
      feed.requests.single.complete(Success([_Video(1)]));
      await tester.idle();
      await query;
      query = feed.onLoadMore();
      if (changeSource) {
        settings.entries[SettingBoxKey.appRcmd] = false;
      } else {
        feed.account = Object();
      }
      feed.updateViewport(itemCount: 1, columns: 1, active: true);
      expect(feed.tokens[1].isCancelled, isTrue);
      expect(feed.indices.last, 0);
      expect(feed.loadingState.value, isA<Loading>());
      feed.requests[1].complete(Success([_Video(2)]));
      feed.requests[2].complete(Success([_Video(3)]));
      await tester.idle();
      await query;
      expect((feed.loadingState.value.data!.single as _Video).aid, 3);
      expect(feed.lastRefreshAt, isNull);
    });
  }

  testWidgets('退出取消下载和旧合作检查的写回', (tester) async {
    final authors = Completer<Set<int>?>();
    feed.lookup = CooperativeAuthors(load: (_) => authors.future);
    addTearDown(() {
      if (!authors.isCompleted) authors.complete(null);
    });
    feed.updateViewport(itemCount: 3, columns: 1, active: true);
    final video = _Video(1, cooperation: true);
    feed.requests.single.complete(Success([video]));
    await tester.idle();
    final state = feed.loadingState.value;
    feed.onDelete();
    expect(feed.tokens.last.isCancelled, isTrue);
    feed.requests.last.complete(Success([_Video(2)]));
    authors.complete({7, 8});
    await tester.idle();
    expect(feed.loadingState.value, same(state));
    expect(video.authors.mids, isNull);
  });

  testWidgets('后台标签不发新请求，返回后继续补足', (tester) async {
    feed.updateViewport(itemCount: 3, columns: 1, active: false);
    expect(feed.requests, isEmpty);
    feed
      ..updateViewport(itemCount: 3, columns: 1, active: true)
      ..updateViewport(itemCount: 3, columns: 1, active: false);
    feed.requests.single.complete(Success([_Video(1)]));
    await tester.idle();
    expect(feed.requests, hasLength(1));
    feed.updateViewport(itemCount: 3, columns: 1, active: true);
    expect(feed.indices, [0, 1]);
  });

  testWidgets('连续五页无增长后停止，空页同样受限', (tester) async {
    feed.updateViewport(itemCount: 3, columns: 1, active: true);
    for (var i = 0; i < 5; i++) {
      feed.requests[i].complete(
        Success(i.isEven ? [_Video(i + 1, mid: 7)] : []),
      );
      await tester.idle();
    }
    expect(feed.requests, hasLength(5));
    expect(feed.canLoadMore, isFalse);
    expect(feed.isLoading, isFalse);
    feed.updateViewport(itemCount: 8, columns: 2, active: true);
    await feed.onLoadMore();
    expect(feed.requests, hasLength(5));
  });

  testWidgets('保留历史位置与顺序，后续页追加在历史之后', (tester) async {
    feed.enableSaveLastData = true;
    feed.loadingState.value = Success([_Video(1), _Video(2)]);
    var query = feed.onRefresh();
    feed.requests.single.complete(Success([_Video(3), _Video(1)]));
    await tester.idle();
    await query;
    expect(feed.lastRefreshAt, 2);
    expect(feed.loadingState.value.data!.map((v) => (v as _Video).aid), [
      3,
      1,
      2,
    ]);
    query = feed.onLoadMore();
    feed.requests.last.complete(Success([_Video(4), _Video(2)]));
    await tester.idle();
    // 两条原始内容仅一条有效，继续补到本次两条增量需求。
    feed.requests.last.complete(Success([_Video(5)]));
    await tester.idle();
    await query;
    expect(feed.lastRefreshAt, 2);
    expect(feed.loadingState.value.data!.map((v) => (v as _Video).aid), [
      3,
      1,
      2,
      4,
      5,
    ]);
    feed.removeRecommendation(feed.loadingState.value.data!.first);
    expect(feed.lastRefreshAt, 1);
  });

  testWidgets('分页失败保留内容并停止自动重试，用户可重试原页', (tester) async {
    var query = feed.onRefresh();
    feed.requests.single.complete(Success([_Video(1)]));
    await tester.idle();
    await query;
    query = feed.onLoadMore();
    feed.requests.last.complete(const Error('网络断开'));
    await tester.idle();
    await query;
    expect(feed.loadingState.value.data, hasLength(1));
    expect(feed.loadMoreError, '网络断开');
    expect(feed.canLoadMore, isFalse);
    await feed.onLoadMore();
    expect(feed.requests, hasLength(2));
    query = feed.retryLoadMore();
    expect(feed.indices, [0, 1, 1]);
    expect(feed.tokens.last.isCancelled, isFalse);
    feed.requests.last.complete(Success([_Video(2), _Video(3)]));
    await tester.idle();
    await query;
    expect(feed.loadingState.value.data, hasLength(3));
    expect(feed.loadMoreError, isNull);
  });

  testWidgets('刷新等待首包期间移除旧卡片，不会清空其他内容或被响应重新插入', (tester) async {
    final removed = _Video(1);
    final kept = _Video(2);
    feed
      ..enableSaveLastData = true
      ..loadingState.value = Success([removed, kept]);
    final query = feed.onRefresh();
    feed.removeRecommendation(removed);
    expect(feed.loadingState.value.data, [kept]);
    feed.requests.single.complete(Success([_Video(1), _Video(3)]));
    await tester.idle();
    await query;
    expect(feed.loadingState.value.data!.map((v) => (v as _Video).aid), [3, 2]);
  });

  testWidgets('合作作者全部命中黑名单时同样在五页后停止', (tester) async {
    feed
      ..lookup = CooperativeAuthors(load: (_) async => {7, 8})
      ..updateViewport(itemCount: 1, columns: 1, active: true);
    for (var index = 0; index < 5; index++) {
      feed.requests[index].complete(
        Success([_Video(index + 1, cooperation: true)]),
      );
      await tester.idle();
    }
    expect(feed.requests, hasLength(5));
    expect(feed.loadingState.value.data, isEmpty);
    expect(feed.isEnd, isTrue);
  });

  testWidgets('刷新期间旧合作作者结果不回写，新请求不保留未检查的历史卡片', (tester) async {
    final authors = Completer<Set<int>?>();
    feed.lookup = CooperativeAuthors(load: (_) => authors.future);
    addTearDown(() {
      if (!authors.isCompleted) authors.complete(null);
    });
    feed.enableSaveLastData = true;
    final video = _Video(1, cooperation: true);
    var query = feed.onRefresh();
    feed.requests.single.complete(Success([video, _Video(2)]));
    await tester.idle();
    await query;
    query = feed.onRefresh();
    expect(feed.loadingState.value.data!.contains(video), isFalse);
    feed.requests.last.complete(Success([_Video(3)]));
    await tester.idle();
    await query;
    authors.complete({8});
    await tester.idle();
    expect(video.authors.mids, isNull);
    expect(feed.loadingState.value.data!.map((v) => (v as _Video).aid), [3, 2]);
  });

  testWidgets('合成时序：同步2秒、下载1秒、合作检查2秒，普通卡片2秒可见', (tester) async {
    final origin = tester.binding.clock.now();
    Duration now() => tester.binding.clock.now().difference(origin);
    final timed = _TimedFeed(now)
      ..lookup = CooperativeAuthors(
        load: (_) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return {8};
        },
      );
    addTearDown(timed.onDelete.call);
    final deliveries = <({int milliseconds, int slots, int ready})>[];
    final subscription = timed.loadingState.listen((state) {
      final items = state.dataOrNull ?? [];
      deliveries.add((
        milliseconds: now().inMilliseconds,
        slots: items.length,
        ready: items.where((item) => !timed.isPending(item)).length,
      ));
    });
    addTearDown(subscription.cancel);
    timed.updateViewport(itemCount: 48, columns: 8, active: true);
    expect(timed.starts.single.milliseconds, 0);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      deliveries.firstWhere((event) => event.ready > 0).milliseconds,
      2000,
    );
    expect(
      deliveries.firstWhere((event) => event.slots >= 48).milliseconds,
      6000,
    );
    expect(
      deliveries.firstWhere((event) => event.ready >= 40).milliseconds,
      lessThanOrEqualTo(6000),
    );
    expect(timed.starts.map((request) => request.milliseconds), [
      0,
      2000,
      3000,
      4000,
      5000,
    ]);
    expect(timed.loadingState.value.data, hasLength(50));
  });

  testWidgets('账号事件主动取消旧请求并重载，无需等待滚动或窗口布局', (tester) async {
    Get.testMode = true;
    final service = Get.put(AccountService());
    addTearDown(Get.reset);
    feed
      ..onInit()
      ..updateViewport(itemCount: 1, columns: 1, active: true)
      ..account = Object();
    service.isLogin.value = true;
    await tester.idle();
    expect(feed.tokens.first.isCancelled, isTrue);
    expect(feed.indices, [0, 0]);
    feed.requests[0].complete(Success([_Video(1)]));
    feed.requests[1].complete(Success([_Video(2)]));
    await tester.idle();
    expect((feed.loadingState.value.data!.single as _Video).aid, 2);
  });

  testWidgets('首页实际网格将未核验合作卡片渲染为骨架，普通卡片可见', (tester) async {
    Get.testMode = true;
    Get.put<RcmdController>(feed);
    addTearDown(Get.reset);
    final authors = Completer<Set<int>?>();
    feed.lookup = CooperativeAuthors(load: (_) => authors.future);
    addTearDown(() {
      if (!authors.isCompleted) authors.complete(null);
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RcmdPage())),
    );
    expect(feed.requests, hasLength(1));
    final cooperation = _Video(1, cooperation: true);
    feed.requests.single.complete(
      Success([
        cooperation,
        ...List.generate(30, (i) => _Video(i + 2)),
      ]),
    );
    await tester.pump();
    expect(find.byType(VideoCardVSkeleton), findsOneWidget);
    expect(find.text('视频 1'), findsNothing);
    expect(find.text('视频 2'), findsOneWidget);
    expect(find.byType(VideoCardV), findsWidgets);
    authors.complete({8});
    await tester.pump();
    expect(find.byType(VideoCardVSkeleton), findsNothing);
    expect(find.text('视频 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('首页补位期间保留骨架，分页失败在页尾提供原页重试', (tester) async {
    Get.testMode = true;
    Get.put<RcmdController>(feed);
    addTearDown(Get.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RcmdPage())),
    );
    final target = feed.viewportItems;
    feed.requests.single.complete(Success([_Video(1, mid: 7)]));
    await tester.pump();
    expect(find.byType(HttpError), findsNothing);
    expect(find.byType(VideoCardVSkeleton), findsWidgets);
    feed.requests.last.complete(
      Success(List.generate(target, (i) => _Video(i + 2))),
    );
    await tester.pump();
    await tester.pump();
    expect(feed.indices, [0, 1]);
    feed.scrollController.jumpTo(
      feed.scrollController.position.maxScrollExtent,
    );
    await tester.pump();
    expect(feed.indices, [0, 1, 2]);
    feed.requests.last.complete(const Error('网络断开'));
    await tester.pump();
    await tester.pump();
    expect(feed.loadingState.value.data, hasLength(target));
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pump();
    expect(feed.indices, [0, 1, 2, 2]);
    feed.requests.last.complete(
      Success(List.generate(target, (i) => _Video(i + target + 2))),
    );
    await tester.pump();
    expect(feed.loadingState.value.data, hasLength(target * 2));
    expect(find.text('加载失败，点击重试'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
