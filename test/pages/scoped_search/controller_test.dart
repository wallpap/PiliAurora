import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/app/interfaces/v1.pb.dart'
    show SearchArchiveReply, SearchArchiveReq, Arc;
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/url.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/pages/live_search/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late LoginAccount account;
  final interceptor = ControlledInterceptor(
    headers: Headers.fromMap({
      'grpc-status': ['0'],
    }),
  );
  final requests = interceptor.requests;
  final dispatched = interceptor.waitForRequests;
  final owner = Object();
  final query = (
    kind: ScopedSearchKind.user,
    keyword: '甲',
    mid: null,
    owner: owner,
  );
  LoginAccount login(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'test'}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> page(List<int> ids, {int total = 80}) => {
    'code': 0,
    'data': {
      'user': {
        'total_user': total,
        'list': [
          for (final id in ids) {'roomid': id, 'name': 'user-$id', 'face': ''},
        ],
      },
    },
  };
  Future<void> ready() async {
    await dispatched(1);
    requests.single.reply.complete(page(List.generate(30, (i) => i + 1)));
    await container.read(scopedSearchProvider(query).future);
  }

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Accounts.account = MemoryBox<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        interceptor,
      );
  });
  setUp(() {
    requests.clear();
    account = login(100);
    Accounts.accountMode[AccountType.main.index] = account;
    Accounts.accountMode[AccountType.recommend.index] = account;
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    Accounts.accountMode[AccountType.recommend.index] = AnonymousAccount();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  test('查询按关键词、分类和页面实例隔离，无输入不请求', () async {
    final qs = [
      query,
      (kind: ScopedSearchKind.room, keyword: '甲', mid: null, owner: owner),
      (kind: ScopedSearchKind.user, keyword: '乙', mid: null, owner: owner),
      (kind: ScopedSearchKind.user, keyword: '甲', mid: null, owner: Object()),
    ];
    final subs = [
      for (final q in qs) container.listen(scopedSearchProvider(q), (_, _) {}),
    ];
    await dispatched(4);
    for (final request in requests) {
      expect(request.options.extra['account'], same(account));
      request.reply.complete(page([], total: 0));
    }
    for (final q in qs) {
      await container.read(scopedSearchProvider(q).future);
    }
    final empty = (
      kind: ScopedSearchKind.user,
      keyword: ' ',
      mid: null,
      owner: owner,
    );
    final sub = container.listen(scopedSearchProvider(empty), (_, _) {});
    await container.read(scopedSearchProvider(empty).future);
    expect(requests, hasLength(4));
    sub.close();
    for (final s in subs) {
      s.close();
    }
  });
  test('分页串行，失败保留页码和数据，显式重试去重', () async {
    final sub = container.listen(scopedSearchProvider(query), (_, _) {});
    await ready();
    final notifier = container.read(scopedSearchProvider(query).notifier);
    final pending = notifier.loadMore();
    await notifier.loadMore();
    await dispatched(2);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await pending;
    expect(
      container.read(scopedSearchProvider(query)).requireValue.nextPage,
      2,
    );
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests.last.options.queryParameters['page'], 2);
    requests.last.reply.complete(page([30, 31], total: 31));
    await retry;
    final data = container.read(scopedSearchProvider(query)).requireValue;
    expect(data.items, hasLength(31));
    expect(data.hasMore, isFalse);
    expect(data.items.clear, throwsUnsupportedError);
    sub.close();
  });
  test('刷新使在途分页失效，失败态不使用旧快照分页', () async {
    final sub = container.listen(scopedSearchProvider(query), (_, _) {});
    await ready();
    final pending = container
        .read(scopedSearchProvider(query).notifier)
        .loadMore();
    await dispatched(2);
    final refresh = container.refresh(scopedSearchProvider(query).future);
    await dispatched(3);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await expectLater(refresh, throwsA(anything));
    requests[1].reply.complete(page([99]));
    await pending;
    expect(container.read(scopedSearchProvider(query)).hasError, isTrue);
    await container.read(scopedSearchProvider(query).notifier).loadMore();
    expect(requests, hasLength(3));
    sub.close();
    await container.pump();
    expect(container.exists(scopedSearchProvider(query)), isFalse);
  });
  test('直播搜索跟随推荐账号，同 UID 新凭据使旧分页失效', () async {
    final sub = container.listen(scopedSearchProvider(query), (_, _) {});
    await ready();
    final pending = container
        .read(scopedSearchProvider(query).notifier)
        .loadMore();
    await dispatched(2);
    Accounts.accountMode[AccountType.main.index] = login(200);
    await Accounts.refresh();
    await container.pump();
    expect(requests, hasLength(2));
    final next = login(100);
    Accounts.accountMode[AccountType.recommend.index] = next;
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    expect(requests.last.options.extra['account'], same(next));
    requests.last.reply.complete(page([50], total: 1));
    await container.read(scopedSearchProvider(query).future);
    requests[1].reply.complete(page([99]));
    await pending;
    expect(
      container
          .read(scopedSearchProvider(query))
          .requireValue
          .items
          .single
          .roomid,
      50,
    );
    sub.close();
  });
  test('空间视频 gRPC 绑定主账号与目标 UID', () async {
    final q = (
      kind: ScopedSearchKind.archive,
      keyword: '视频',
      mid: 200,
      owner: owner,
    );
    final sub = container.listen(scopedSearchProvider(q), (_, _) {});
    await dispatched(1);
    expect(requests.single.options.path, endsWith(GrpcUrl.searchArchive));
    expect(requests.single.options.extra['account'], same(account));
    final request = SearchArchiveReq.fromBuffer(
      GrpcReq.decompressProtobuf(requests.single.options.data),
    );
    expect(request.mid.toInt(), 200);
    expect(request.pn.toInt(), 1);
    expect(request.keyword, '视频');
    requests.single.reply.complete(
      GrpcReq.compressProtobuf(
        SearchArchiveReply(
          archives: [Arc()..ensureArchive().aid = Int64(42)],
          total: Int64(1),
        ).writeToBuffer(),
      ),
    );
    final data = await container.read(scopedSearchProvider(q).future);
    expect(data.hasMore, isFalse);
    expect(data.items.single.archive.aid.toInt(), 42);
    sub.close();
  });
  test('空间动态过滤后的空页按游标继续，连续五页无增长后停止', () async {
    final q = (
      kind: ScopedSearchKind.dynamic,
      keyword: '动态',
      mid: 200,
      owner: owner,
    );
    final sub = container.listen(scopedSearchProvider(q), (_, _) {});
    await dispatched(1);
    expect(requests.single.options.path, Api.dynSearch);
    requests.single.reply.complete({
      'code': 0,
      'data': {'items': [], 'has_more': true, 'offset': '1'},
    });
    await container.read(scopedSearchProvider(q).future);
    for (var i = 2; i <= 5; i++) {
      final more = container.read(scopedSearchProvider(q).notifier).loadMore();
      await dispatched(i);
      expect(requests.last.options.queryParameters['offset'], '${i - 1}');
      requests.last.reply.complete({
        'code': 0,
        'data': {'items': [], 'has_more': true, 'offset': '$i'},
      });
      await more;
    }
    expect(
      container.read(scopedSearchProvider(q)).requireValue.hasMore,
      isFalse,
    );
    sub.close();
  });
  testWidgets('搜索未提交不请求，替换输入隐藏旧计数，清空后可重新提交', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LiveSearchPage()),
      ),
    );
    expect(requests, isEmpty);
    await tester.enterText(find.byType(TextField), '甲');
    expect(requests, isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(2);
      for (final request in requests) {
        request.reply.complete(page([], total: 7));
      }
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('主播 7'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '乙');
    await tester.pumpAndSettle();
    expect(find.text('主播 7'), findsNothing);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '甲');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(4);
      for (final request in requests.skip(2)) {
        request.reply.complete(page([], total: 0));
      }
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
  });

  test('不同关键词的迟到响应互不覆盖，空间动态重复游标停止', () async {
    final other = (
      kind: ScopedSearchKind.user,
      keyword: '乙',
      mid: null,
      owner: owner,
    );
    final a = container.listen(scopedSearchProvider(query), (_, _) {});
    final b = container.listen(scopedSearchProvider(other), (_, _) {});
    await dispatched(2);
    requests.last.reply.complete(page([2], total: 1));
    await container.read(scopedSearchProvider(other).future);
    requests.first.reply.complete(page([1], total: 1));
    await container.read(scopedSearchProvider(query).future);
    expect(
      container
          .read(scopedSearchProvider(other))
          .requireValue
          .items
          .single
          .roomid,
      2,
    );
    a.close();
    b.close();
    final q = (
      kind: ScopedSearchKind.dynamic,
      keyword: '动态',
      mid: 200,
      owner: owner,
    );
    final sub = container.listen(scopedSearchProvider(q), (_, _) {});
    await dispatched(3);
    requests.last.reply.complete({
      'code': 0,
      'data': {'items': [], 'has_more': true, 'offset': 'same'},
    });
    await container.read(scopedSearchProvider(q).future);
    final more = container.read(scopedSearchProvider(q).notifier).loadMore();
    await dispatched(4);
    requests.last.reply.complete({
      'code': 0,
      'data': {'items': [], 'has_more': true, 'offset': 'same'},
    });
    await more;
    expect(
      container.read(scopedSearchProvider(q)).requireValue.hasMore,
      isFalse,
    );
    sub.close();
  });
}
