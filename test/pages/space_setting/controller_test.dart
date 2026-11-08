import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space_setting/privacy.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/space_setting/controller.dart';
import 'package:pili_aurora/pages/space_setting/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _PrivacyNotifier extends SpacePrivacyNotifier {
  final saves = <Completer<LoadingState<void>>>[];
  @override
  Future<SpacePrivacyState> build() async => SpacePrivacyState(
    privacy: Privacy.fromJson({'fav_video': 0}),
    confirmed: {'fav_video': 0},
  );
  @override
  Future<LoadingState<void>> save() {
    final reply = Completer<LoadingState<void>>();
    saves.add(reply);
    return reply.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final dispatched = interceptor.waitForRequests;
  late ProviderContainer container;
  late LoginAccount account;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '100', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> settings() => {
    'code': 0,
    'data': {
      'privacy': {'fav_video': 0, 'disable_following': 0},
    },
  };
  SpacePrivacyState current() =>
      container.read(spacePrivacyProvider).requireValue;
  Future<void> load() async {
    container.listen(spacePrivacyProvider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(settings());
    await container.read(spacePrivacyProvider.future);
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
    account = login('old');
    Accounts.accountMode[AccountType.main.index] = account;
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
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('账号绑定、反向字段、草稿与不可变快照', () async {
    await load();
    expect(requests.single.options.path, Api.spaceSetting);
    expect(requests.single.options.extra['account'], same(account));
    expect(requests.single.options.queryParameters['mid'], 100);
    final before = current();
    final notifier = container.read(spacePrivacyProvider.notifier)
      ..setValue('fav_video', true)
      ..setValue('disable_following', false);
    expect(current().values['fav_video'], 1);
    expect(current().values['disable_following'], 1);
    expect(before.values['fav_video'], 0);
    expect(current().dirty, isTrue);
    expect(() => current().values.clear(), throwsUnsupportedError);
    expect(before.privacy.list1.clear, throwsUnsupportedError);
    notifier
      ..setValue('fav_video', false)
      ..setValue('disable_following', true)
      ..setValue('invalid', true);
    expect(current().dirty, isFalse);
    expect((await notifier.save()).isSuccess, isTrue);
    expect(requests, hasLength(1));
  });

  test('保存串行、失败保留草稿、成功确认，账号与 CSRF 一致', () async {
    await load();
    final notifier = container.read(spacePrivacyProvider.notifier)
      ..setValue('fav_video', true);
    final first = notifier.save();
    expect((await notifier.save()).isSuccess, isFalse);
    notifier.setValue('fav_video', false);
    await dispatched(2);
    final request = requests.last.options;
    expect(request.path, Api.spaceSettingMod);
    expect(request.extra['account'], same(account));
    expect(request.extra['noRetry'], isTrue);
    expect(request.queryParameters['csrf'], 'old');
    expect(request.data['fav_video'], 1);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    expect((await first).isSuccess, isFalse);
    expect(current().saving, isFalse);
    expect(current().dirty, isTrue);
    expect(current().values['fav_video'], 1);
    final retry = notifier.save();
    await dispatched(3);
    requests.last.reply.complete({'code': 0});
    expect((await retry).isSuccess, isTrue);
    expect(current().dirty, isFalse);
    expect(current().confirmed['fav_video'], 1);
  });

  test('同 UID 新凭据与刷新隔离迟到保存，错误保留值不能写入', () async {
    await load();
    final notifier = container.read(spacePrivacyProvider.notifier)
      ..setValue('fav_video', true);
    final save = notifier.save();
    await dispatched(2);
    final next = login('new');
    Accounts.accountMode[AccountType.main.index] = next;
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    notifier.setValue('fav_video', false);
    expect((await notifier.save()).isSuccess, isFalse);
    requests[2].reply.complete(settings());
    await container.read(spacePrivacyProvider.future);
    requests[1].reply.complete({'code': 0});
    expect((await save).isSuccess, isFalse);
    expect(current().values['fav_video'], 0);
    notifier.setValue('fav_video', true);
    container.invalidate(spacePrivacyProvider);
    await container.pump();
    await dispatched(4);
    requests.last.reply.complete({'code': -1, 'message': 'query failed'});
    await expectLater(
      container.read(spacePrivacyProvider.future),
      throwsA(anything),
    );
    notifier.setValue('fav_video', false);
    expect((await notifier.save()).isSuccess, isFalse);
    expect(requests, hasLength(4));
  });

  test('查询刷新后旧保存不能覆盖新快照，释放不触发保存', () async {
    await load();
    final notifier = container.read(spacePrivacyProvider.notifier)
      ..setValue('fav_video', true);
    final save = notifier.save();
    await dispatched(2);
    container.invalidate(spacePrivacyProvider);
    await container.pump();
    await dispatched(3);
    requests.last.reply.complete(settings());
    await container.read(spacePrivacyProvider.future);
    requests[1].reply.complete({'code': 0});
    expect((await save).isSuccess, isFalse);
    expect(current().values['fav_video'], 0);
    notifier.setValue('fav_video', true);
    container.invalidate(spacePrivacyProvider);
    expect(requests, hasLength(3));
  });

  testWidgets('返回等待保存，失败留页重试，成功离页且释放无写入', (tester) async {
    container.dispose();
    final notifier = _PrivacyNotifier();
    container = ProviderContainer(
      overrides: [spacePrivacyProvider.overrideWith(() => notifier)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: GetMaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Get.to<void>(() => const SpaceSettingPage()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公开我的收藏'));
    await tester.pumpAndSettle();
    expect(current().dirty, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(notifier.saves, hasLength(1));
    expect(find.text('空间设置'), findsOneWidget);
    notifier.saves.last.complete(const Error('failed'));
    await tester.pumpAndSettle();
    expect(find.text('failed'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(notifier.saves, hasLength(2));
    notifier.saves.last.complete(const Success(null));
    await tester.pumpAndSettle();
    expect(find.text('空间设置'), findsNothing);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
    expect(notifier.saves, hasLength(2));
    expect(requests, isEmpty);
  });
}
