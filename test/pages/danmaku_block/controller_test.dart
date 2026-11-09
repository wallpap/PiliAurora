import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Transition;
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/dm_block_type.dart';
import 'package:pili_aurora/pages/danmaku_block/controller.dart';
import 'package:pili_aurora/pages/danmaku_block/view.dart';
import 'package:pili_aurora/models/user/danmaku_block.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Player implements PlPlayerController {
  @override
  RuleFilter filters = RuleFilter(['cached'], [], {});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockNotifier extends DanmakuBlockNotifier {
  _BlockNotifier(this.initial);
  final DanmakuBlockState initial;
  @override
  DanmakuBlockState build() => initial;
  void publish(DanmakuBlockState value) => state = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final dispatched = interceptor.waitForRequests;
  late ProviderContainer container;
  late ProviderSubscription<DanmakuBlockState> subscription;
  late Account account;

  LoginAccount login(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-$mid'}),
    null,
    null,
  )..activated = true;

  Future<void> select(Account value) async {
    Accounts.accountMode[AccountType.main.index] = value;
    await Accounts.refresh();
    await container.pump();
  }

  Map<String, dynamic> rule(int id, {int type = 0, String filter = 'word'}) => {
    'id': id,
    'type': type,
    'filter': filter,
  };
  Map<String, dynamic> rules(List<Map<String, dynamic>> entries) => {
    'code': 0,
    'data': {'rule': entries},
  };

  Future<void> loaded() async {
    await dispatched(1);
    requests[0].reply.complete(rules([rule(1)]));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(danmakuBlockProvider).rules, isA<Success>());
  }

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Accounts.account = MemoryBox<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.interceptors.add(
      interceptor,
    );
  });

  setUp(() {
    requests.clear();
    account = login(123);
    Accounts.accountMode[AccountType.main.index] = account;
    container = ProviderContainer();
    subscription = container.listen(danmakuBlockProvider, (_, _) {});
  });
  tearDown(() {
    subscription.close();
    container.dispose();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    for (final pending in requests) {
      if (!pending.reply.isCompleted) pending.reply.complete(rules([]));
    }
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('加载规则不可变，刷新替换而非追加；迟到查询不覆盖新查询', () async {
    await loaded();
    final initial = container.read(danmakuBlockProvider).rules.data;
    expect(initial.clear, throwsUnsupportedError);
    expect(() => initial.first.clear(), throwsUnsupportedError);
    final notifier = container.read(danmakuBlockProvider.notifier);
    final old = notifier.reload();
    await dispatched(2);
    final latest = notifier.reload();
    await dispatched(3);
    requests[2].reply.complete(rules([rule(3)]));
    await latest;
    requests[1].reply.complete(rules([rule(2)]));
    await old;
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 3);
  });

  test('编辑删除失败时保留原规则，不发送添加请求并解锁', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    expect(container.read(danmakuBlockProvider).isSaving, isTrue);
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    expect(await editing, isA<Error>());
    expect(requests, hasLength(2));
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 1);
    expect(container.read(danmakuBlockProvider).isSaving, isFalse);
  });

  test('删除成功但添加失败，保留已确认的删除结果并说明部分成功', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    requests[1].reply.complete({'code': 0});
    await dispatched(3);
    expect(container.read(danmakuBlockProvider).rules.data.first, isEmpty);
    requests[2].reply.complete({'code': -1, 'message': 'failed'});
    expect((await editing).toString(), contains('原规则已删除'));
    expect(container.read(danmakuBlockProvider).rules.data.first, isEmpty);
  });

  test('删除结果待确认时保留原规则，不继续提交添加', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    requests[1].reply.complete({'message': 'missing status'});
    final result = await editing as UnknownResult;
    expect(result.cause, isA<FormatException>());
    expect(requests, hasLength(2));
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 1);
    expect(container.read(danmakuBlockProvider).isSaving, isFalse);
  });

  test('删除已确认但添加响应损坏时保留待确认类型和部分成功说明', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    requests[1].reply.complete({'code': 0});
    await dispatched(3);
    requests[2].reply.complete({'code': 0, 'data': {}});
    final result = await editing as UnknownResult;
    expect(result.cause, isNotNull);
    expect(result.stackTrace, isNotNull);
    expect(result.toString(), contains('原规则已删除，添加结果待确认'));
    expect(container.read(danmakuBlockProvider).rules.data.first, isEmpty);
    expect(container.read(danmakuBlockProvider).isSaving, isFalse);
  });

  test('写入期间拒绝重复写和刷新；UID 只哈希一次且账号/CSRF 固定', () async {
    await loaded();
    final notifier = container.read(danmakuBlockProvider.notifier);
    final saving = notifier.save(DmBlockType.uid, '456');
    await dispatched(2);
    final options = requests[1].options;
    expect(options.path, Api.danmakuFilterAdd);
    expect(options.extra['account'], same(account));
    expect(options.extra['noRetry'], isTrue);
    expect((options.data as Map)['csrf'], account.csrf);
    expect(
      (options.data as Map)['filter'],
      'b1a8c371',
    );
    expect(await notifier.remove(DmBlockType.keyword, 1), isA<Error>());
    await notifier.reload();
    expect(requests, hasLength(2));
    requests[1].reply.complete({
      'code': 0,
      'data': rule(2, type: 2, filter: 'hash'),
    });
    expect(await saving, isA<Success>());
    expect(container.read(danmakuBlockProvider).rules.data[2].single.id, 2);
  });

  test('无效正则和 UID 在删除原规则前被拒绝', () async {
    await loaded();
    final notifier = container.read(danmakuBlockProvider.notifier);
    expect(
      await notifier.save(DmBlockType.regex, '[', replaceId: 1),
      isA<Error>(),
    );
    expect(await notifier.save(DmBlockType.uid, 'a'), isA<Error>());
    expect(requests, hasLength(1));
  });

  test('切换到同 mid 新凭据会重建状态，旧查询不会写入新状态', () async {
    await dispatched(1);
    final replacement = login(123);
    expect(replacement, equals(account));
    Accounts.replaceCredentials(replacement);
    await container.pump();
    expect(replacement.type, contains(AccountType.main));
    expect(container.read(mainAccountProvider), same(replacement));
    await dispatched(2);
    requests[1].reply.complete(rules([rule(2)]));
    await Future<void>.delayed(Duration.zero);
    requests[0].reply.complete(rules([rule(1)]));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 2);
  });

  test('编辑删除期间切号后不向新账号发起添加，不改变新账号状态', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    await select(login(456));
    await dispatched(3);
    requests[2].reply.complete(rules([rule(3)]));
    await Future<void>.delayed(Duration.zero);
    requests[1].reply.complete({'code': 0});
    expect(await editing, isA<Error>());
    expect(requests, hasLength(3));
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 3);
    expect(container.read(danmakuBlockProvider).isSaving, isFalse);
  });

  test('最后订阅释放后编辑停止后续请求，重新进入重新查询', () async {
    await loaded();
    final editing = container
        .read(danmakuBlockProvider.notifier)
        .save(
          DmBlockType.keyword,
          'new',
          replaceId: 1,
        );
    await dispatched(2);
    subscription.close();
    await container.pump();
    expect(container.exists(danmakuBlockProvider), isFalse);
    expect(container.exists(mainAccountProvider), isFalse);
    requests[1].reply.complete({'code': 0});
    expect(await editing, isA<Error>());
    expect(requests, hasLength(2));
    subscription = container.listen(danmakuBlockProvider, (_, _) {});
    await dispatched(3);
  });

  test('退出登录清除页面状态且不发起匿名规则查询', () async {
    await loaded();
    await select(AnonymousAccount());
    expect(container.read(danmakuBlockProvider).rules, isA<Error>());
    expect(requests, hasLength(1));
  });

  test('加载失败可重试，成功加载后恢复规则列表', () async {
    await dispatched(1);
    requests[0].reply.complete({'code': -1, 'message': 'failed'});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(danmakuBlockProvider).rules, isA<Error>());
    final reloading = container.read(danmakuBlockProvider.notifier).reload();
    await dispatched(2);
    requests[1].reply.complete(rules([rule(2)]));
    await reloading;
    expect(container.read(danmakuBlockProvider).rules.data.first.single.id, 2);
  });

  for (final succeeds in [true, false]) {
    testWidgets('页面${succeeds ? '成功规则立即应用' : '加载失败保留缓存'}，退出不清空过滤器', (
      tester,
    ) async {
      final player = _Player();
      final cached = player.filters;
      final notifier = _BlockNotifier(
        DanmakuBlockState(
          rules: succeeds
              ? Success([
                  [SimpleRule.fromJson(rule(1))],
                  const <SimpleRule>[],
                  const <SimpleRule>[],
                ])
              : const Error('fixture failure'),
        ),
      );
      await GStorage.localCache.put(LocalCacheKey.danmakuFilterRules, cached);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [danmakuBlockProvider.overrideWith(() => notifier)],
          child: GetMaterialApp(
            home: Scaffold(
              body: TextButton(
                onPressed: () =>
                    Get.to(() => const DanmakuBlockPage(), arguments: player),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(player.filters.dmFilterString, succeeds ? ['word'] : ['cached']);
      final applied = player.filters;
      notifier.publish(
        DanmakuBlockState(rules: const Error('refresh failure')),
      );
      await tester.pumpAndSettle();
      expect(player.filters, same(applied));
      Get.back();
      await tester.pumpAndSettle();
      expect(player.filters, same(applied));
      expect(
        GStorage.localCache.get(LocalCacheKey.danmakuFilterRules),
        same(applied),
      );
      await tester.pumpWidget(const SizedBox());
      Get.reset();
    });
  }
}
