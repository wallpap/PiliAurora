import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/live_area/controller.dart';
import 'package:pili_aurora/pages/live_area/view.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/live_dm_block/controller.dart';
import 'package:pili_aurora/pages/live_dm_block/view.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Box<T> implements Box<T> {
  final valuesMap = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => valuesMap[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async {
    valuesMap[key] = value;
  }

  @override
  Iterable<T> get values => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RulesNotifier extends LiveBlockNotifier {
  _RulesNotifier() : super('12');
  @override
  Future<LiveBlockState> build() async =>
      LiveBlockState(keywords: ['old'], users: []);
  void fail() => state = AsyncError('failed', StackTrace.current);
}

class _PreferencesNotifier extends LiveAreaPreferencesNotifier {
  final saves = <Completer<LoadingState<void>>>[];
  @override
  Future<LiveAreaPreferences> build() async => LiveAreaPreferences([]);
  void replace() => state = AsyncData(LiveAreaPreferences([]));
  @override
  Future<LoadingState<void>> save(Object source, List<AreaItem> draft) {
    final reply = Completer<LoadingState<void>>();
    saves.add(reply);
    return reply.future;
  }
}

typedef _Pending = ({
  RequestOptions options,
  Completer<Map<String, dynamic>> reply,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <_Pending>[];
  late ProviderContainer container;
  late LoginAccount account;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '100', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  const room = '12';
  final provider = liveBlockProvider(room);
  Map<String, dynamic> rules() => {
    'code': 0,
    'data': {
      'shield_info': {
        'keyword_list': ['old'],
        'shield_user_list': [
          {'uid': 2, 'uname': 'two'},
        ],
      },
    },
  };
  Map<String, dynamic> tags(List<int> ids) => {
    'code': 0,
    'data': {
      'tags': [
        for (final id in ids) {'id': id, 'name': 'tag$id', 'parent_id': 1},
      ],
    },
  };
  Future<void> dispatched(int count) async {
    for (var i = 0; i < 100 && requests.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, hasLength(count));
  }

  LiveBlockState current() => container.read(provider).requireValue;
  Future<void> loadRules() async {
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(rules());
    await container.read(provider.future);
  }

  Future<void> loadTags() async {
    container.listen(liveAreaPreferencesProvider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(tags([1, 2]));
    await container.read(liveAreaPreferencesProvider.future);
  }

  setUpAll(() {
    GStorage.setting = _Box<dynamic>();
    GStorage.localCache = _Box<dynamic>();
    Accounts.account = _Box<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final reply = Completer<Map<String, dynamic>>();
            requests.add((options: options, reply: reply));
            handler.resolve(
              Response(requestOptions: options, data: await reply.future),
            );
          },
        ),
      );
  });
  setUp(() {
    requests.clear();
    GStorage.localCache.put(
      LocalCacheKey.mixinKey,
      '01234567890123456789012345678901',
    );
    GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    account = login('old');
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
    Get.reset();
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('直播规则读取绑定房间和账号，成功后不可变快照', () async {
    await loadRules();
    expect(requests.single.options.path, Api.getLiveInfoByUser);
    expect(requests.single.options.queryParameters['room_id'], room);
    expect(requests.single.options.extra['account'], same(account));
    final before = current();
    final save = container
        .read(provider.notifier)
        .change(source: before.source, keyword: true, value: 'new');
    await dispatched(2);
    expect(current().saving, isTrue);
    expect(requests.last.options.extra['noRetry'], isTrue);
    expect(requests.last.options.extra['account'], same(account));
    expect(requests.last.options.data['csrf'], 'old');
    requests.last.reply.complete({'code': 0});
    expect((await save).isSuccess, isTrue);
    expect(current().keywords, ['new', 'old']);
    expect(before.keywords, ['old']);
    expect(() => current().keywords.clear(), throwsUnsupportedError);
    expect(
      (await container
              .read(provider.notifier)
              .change(source: before.source, keyword: true, value: 'stale'))
          .isSuccess,
      isFalse,
    );
    expect(requests, hasLength(2));
  });

  test('规则操作串行、失败不删、用户增删固定房间及 CSRF', () async {
    await loadRules();
    final notifier = container.read(provider.notifier);
    final remove = notifier.change(
      source: current().source,
      keyword: true,
      value: 'old',
      remove: true,
    );
    expect(
      (await notifier.change(
        source: current().source,
        keyword: true,
        value: 'other',
      )).isSuccess,
      isFalse,
    );
    await dispatched(2);
    expect(requests.last.options.path, Api.delShieldKeyword);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    expect((await remove).isSuccess, isFalse);
    expect(current().keywords, ['old']);
    final add = notifier.change(
      source: current().source,
      keyword: false,
      value: '3',
    );
    await dispatched(3);
    expect(requests.last.options.data['roomid'], room);
    expect(requests.last.options.data['csrf_token'], 'old');
    expect(requests.last.options.data['type'], 1);
    requests.last.reply.complete({
      'code': 0,
      'data': {'uid': 3, 'uname': 'three'},
    });
    expect((await add).isSuccess, isTrue);
    final del = notifier.change(
      source: current().source,
      keyword: false,
      value: '3',
      remove: true,
    );
    await dispatched(4);
    expect(requests.last.options.data['type'], 0);
    requests.last.reply.complete({'code': 0, 'data': null});
    expect((await del).isSuccess, isTrue);
    expect(current().users.map((e) => e.uid), [2]);
  });

  test('切号与刷新丢弃迟到写入，查询失败不能使用保留值写入', () async {
    await loadRules();
    final notifier = container.read(provider.notifier);
    final source = current().source;
    final add = notifier.change(source: source, keyword: true, value: 'late');
    await dispatched(2);
    Accounts.accountMode[AccountType.main.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    requests[2].reply.complete(rules());
    await container.read(provider.future);
    requests[1].reply.complete({'code': 0});
    expect((await add).isSuccess, isFalse);
    expect(current().keywords, ['old']);
    expect(
      (await notifier.change(
        source: source,
        keyword: true,
        value: 'stale',
      )).isSuccess,
      isFalse,
    );
    container.invalidate(provider);
    await container.pump();
    await dispatched(4);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await expectLater(container.read(provider.future), throwsA(anything));
    expect(
      (await notifier.change(
        source: source,
        keyword: true,
        value: 'bad',
      )).isSuccess,
      isFalse,
    );
    expect(requests, hasLength(4));
  });

  test('分区目录跟随推荐账号，常用标签独立绑定主账号', () async {
    final recommend = login('recommend');
    Accounts.accountMode[AccountType.recommend.index] = recommend;
    container
      ..listen(liveAreasProvider, (_, _) {})
      ..listen(liveAreaPreferencesProvider, (_, _) {});
    await dispatched(2);
    for (final request in requests) {
      if (request.options.path == Api.liveAreaList) {
        expect(request.options.extra['account'], same(recommend));
        request.reply.complete({
          'code': 0,
          'data': {'list': []},
        });
      } else {
        expect(request.options.path, Api.getLiveFavTag);
        expect(request.options.extra['account'], same(account));
        request.reply.complete(tags([1, 2]));
      }
    }
    await container.read(liveAreasProvider.future);
    await container.read(liveAreaPreferencesProvider.future);
    Accounts.accountMode[AccountType.main.index] = login('next');
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    expect(requests.last.options.path, Api.getLiveFavTag);
  });

  test('标签草稿失败不污染确认列表，重试成功按排序去重保存', () async {
    await loadTags();
    final before = container.read(liveAreaPreferencesProvider).requireValue;
    final draft = before.items.reversed.toList();
    final notifier = container.read(liveAreaPreferencesProvider.notifier);
    final save = notifier.save(before.source, draft);
    expect((await notifier.save(before.source, draft)).isSuccess, isFalse);
    await dispatched(2);
    expect(requests.last.options.path, Api.setLiveFavTag);
    expect(requests.last.options.data['tags'], '2,1');
    expect(requests.last.options.extra['account'], same(account));
    expect(requests.last.options.extra['noRetry'], isTrue);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    expect((await save).isSuccess, isFalse);
    expect(
      container
          .read(liveAreaPreferencesProvider)
          .requireValue
          .items
          .map((e) => e.id),
      [1, 2],
    );
    final retry = notifier.save(before.source, [...draft, draft.first]);
    await dispatched(3);
    expect(requests.last.options.data['tags'], '2,1');
    requests.last.reply.complete({'code': 0});
    expect((await retry).isSuccess, isTrue);
    final after = container.read(liveAreaPreferencesProvider).requireValue;
    expect(after.items.map((e) => e.id), [2, 1]);
    expect(after.items.clear, throwsUnsupportedError);
    expect((await notifier.save(before.source, draft)).isSuccess, isFalse);
  });

  test('标签切号和释放隔离迟到保存，旧草稿不能提交新账号', () async {
    await loadTags();
    final before = container.read(liveAreaPreferencesProvider).requireValue;
    final notifier = container.read(liveAreaPreferencesProvider.notifier);
    final save = notifier.save(before.source, before.items.reversed.toList());
    await dispatched(2);
    Accounts.accountMode[AccountType.main.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    requests[2].reply.complete(tags([4]));
    await container.read(liveAreaPreferencesProvider.future);
    requests[1].reply.complete({'code': 0});
    expect((await save).isSuccess, isFalse);
    expect(
      container.read(liveAreaPreferencesProvider).requireValue.items.single.id,
      4,
    );
    expect(
      (await notifier.save(before.source, before.items)).isSuccess,
      isFalse,
    );
  });

  testWidgets('旧标签保存不阻塞新快照编辑，迟到结果不关闭新草稿', (tester) async {
    container.dispose();
    final notifier = _PreferencesNotifier();
    container = ProviderContainer(
      overrides: [
        liveAreaPreferencesProvider.overrideWith(() => notifier),
        liveAreasProvider.overrideWith((_) => []),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LiveAreaPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(notifier.saves, hasLength(1));
    notifier.replace();
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    notifier.saves.first.complete(const Success(null));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(notifier.saves, hasLength(2));
    notifier.saves.last.complete(const Success(null));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
  });

  testWidgets('规则仅在成功读取后回调，失败与离页不清空播放器规则', (tester) async {
    container.dispose();
    final notifier = _RulesNotifier();
    container = ProviderContainer(
      overrides: [provider.overrideWith(() => notifier)],
    )..listen(provider, (_, _) {});
    await tester.pump();
    final changes = <List<String>>[];
    void callback(List<String> words, Set<int> uids) => changes.add(words);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: GetMaterialApp(
          getPages: [
            GetPage(name: '/rules', page: () => const LiveDmBlockPage()),
          ],
          home: Builder(
            builder: (_) => TextButton(
              onPressed: () => Get.toNamed<void>(
                '/rules',
                arguments: callback,
                parameters: {'roomId': room},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(changes, [
      ['old'],
    ]);
    notifier.fail();
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
    expect(requests, isEmpty);
  });
}
