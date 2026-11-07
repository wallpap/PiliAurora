import 'dart:async';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart' as loading;
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/log_table/controller.dart';
import 'package:pili_aurora/pages/log_table/view.dart';
import 'package:pili_aurora/pages/login_devices/controller.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Box<T> implements Box<T> {
  final storedValues = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => storedValues[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async {
    storedValues[key] = value;
  }

  @override
  Iterable<T> get values => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  LoginAccount login(int mid, String credential) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': credential}),
    'access-$credential',
    null,
  )..activated = true;
  Future<void> dispatched(int count) async {
    for (var i = 0; i < 100 && requests.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, hasLength(count));
  }

  Future<void> select(LoginAccount value) async {
    Accounts.accountMode[AccountType.main.index] = value;
    await Accounts.refresh();
    await container.pump();
  }

  Map<String, dynamic> loginRows(String marker) => {
    'code': 0,
    'data': {
      'list': [
        {'time_at': '$marker-time', 'ip': '$marker-ip', 'geo': '$marker-geo'},
        {'time_at': 'second', 'ip': 'second-ip', 'geo': 'second-geo'},
      ],
    },
  };
  Map<String, dynamic> coinRows(String marker) => {
    'code': 0,
    'data': {
      'list': [
        {'time': '$marker-time', 'delta': 1, 'reason': '$marker-reason'},
      ],
    },
  };
  Map<String, dynamic> devices(String marker) => {
    'code': 0,
    'data': {
      'devices': [
        {
          'device_name': marker,
          'is_current_device': true,
          'latest_login_at': 'today',
          'source': 'here',
        },
      ],
    },
  };

  setUpAll(() {
    GStorage.setting = _Box<dynamic>();
    GStorage.localCache = _Box<dynamic>()
      ..storedValues[LocalCacheKey.buvid] = 'fixture-buvid';
    Accounts.account = _Box<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.interceptors.add(
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
    account = login(100, 'old');
    Accounts.accountMode[AccountType.main.index] = account;
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    for (final pending in requests) {
      if (!pending.reply.isCompleted) {
        pending.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('各日志请求隔离并保留列与行顺序', () async {
    final subscriptions = [
      for (final type in LogType.values)
        container.listen(logTableProvider(type), (_, _) {}),
    ];
    await dispatched(3);
    expect(requests.map((r) => r.options.path), [
      Api.loginLog,
      Api.coinLog,
      Api.expLog,
    ]);
    for (final request in requests) {
      expect(request.options.extra['account'], same(account));
    }
    requests[0].reply.complete(loginRows('login'));
    requests[1].reply.complete(coinRows('coin'));
    requests[2].reply.complete(coinRows('exp'));
    final login = (await container.read(
      logTableProvider(LogType.login).future,
    ));
    final coin = (await container.read(logTableProvider(LogType.coin).future));
    final exp = (await container.read(logTableProvider(LogType.exp).future));
    expect(LogType.login.header, [(3, '时间'), (2, '变化'), (3, '地理位置')]);
    expect(login, [
      [(3, 'login-time'), (2, 'login-ip'), (3, 'login-geo')],
      [(3, 'second'), (2, 'second-ip'), (3, 'second-geo')],
    ]);
    expect(coin.single, [(3, 'coin-time'), (1, '1'), (4, 'coin-reason')]);
    expect(exp.single, [(2, 'exp-time'), (1, '1'), (2, 'exp-reason')]);
    expect(() => login.first.clear(), throwsUnsupportedError);
    for (final sub in subscriptions) {
      sub.close();
    }
  });

  test('切换账号和同一 mid 换凭据后旧请求不能覆盖结果', () async {
    final provider = logTableProvider(LogType.login);
    final sub = container.listen(provider, (_, _) {});
    await dispatched(1);
    final second = login(200, 'second');
    await select(second);
    await dispatched(2);
    final replacement = login(200, 'replacement');
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(3);
    expect(requests.map((r) => r.options.extra['account']), [
      same(account),
      same(second),
      same(replacement),
    ]);
    requests[2].reply.complete(loginRows('new'));
    final latest = await container.read(provider.future);
    requests[0].reply.complete(loginRows('old'));
    requests[1].reply.complete(loginRows('stale'));
    await Future<void>.delayed(Duration.zero);
    expect(latest.first.first.$2, 'new-time');
    expect(container.read(provider).value!.first.first.$2, 'new-time');
    sub.close();
  });

  test('设备请求绑定发起账号并在释放后忽略迟到响应', () async {
    final sub = container.listen(loginDevicesProvider, (_, _) {});
    await dispatched(1);
    expect(requests.single.options.extra['account'], same(account));
    expect(requests.single.options.queryParameters['csrf'], 'old');
    expect(requests.single.options.queryParameters['access_key'], 'access-old');
    sub.close();
    await container.pump();
    expect(container.exists(loginDevicesProvider), isFalse);
    expect(container.exists(mainAccountProvider), isFalse);
    requests.single.reply.complete(devices('late'));
    await Future<void>.delayed(Duration.zero);
    expect(container.exists(loginDevicesProvider), isFalse);
  });

  test('设备查询切号后绑定新凭据并忽略旧响应', () async {
    final sub = container.listen(loginDevicesProvider, (_, _) {});
    await dispatched(1);
    final replacement = login(100, 'replacement');
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(2);
    expect(requests[1].options.extra['account'], same(replacement));
    expect(requests[1].options.queryParameters['csrf'], 'replacement');
    requests[1].reply.complete(devices('new-device'));
    final latest = await container.read(loginDevicesProvider.future);
    requests[0].reply.complete(devices('old-device'));
    await Future<void>.delayed(Duration.zero);
    expect(latest.single.deviceName, 'new-device');
    expect(
      container.read(loginDevicesProvider).value!.single.deviceName,
      'new-device',
    );
    sub.close();
  });

  test('错误响应和解析异常可通过刷新重试', () async {
    final provider = logTableProvider(LogType.coin);
    final sub = container.listen(provider, (_, _) {});
    await dispatched(1);
    final failed = expectLater(
      container.read(provider.future),
      throwsA(isA<loading.Error>()),
    );
    requests[0].reply.complete({'code': -1, 'message': 'failed'});
    await failed;
    final retry = container.refresh(provider.future);
    await dispatched(2);
    final invalid = expectLater(retry, throwsA(isA<loading.Error>()));
    requests[1].reply.complete({'code': 0, 'data': null});
    await invalid;
    final again = container.refresh(provider.future);
    await dispatched(3);
    requests[2].reply.complete(coinRows('retry'));
    expect((await again).single.first.$2, 'retry-time');
    sub.close();
  });

  test('未登录时不发送账号查询', () async {
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    final deviceSub = container.listen(loginDevicesProvider, (_, _) {});
    final logSub = container.listen(logTableProvider(LogType.login), (_, _) {});
    await expectLater(
      container.read(loginDevicesProvider.future),
      throwsA(isA<loading.Error>()),
    );
    await expectLater(
      container.read(logTableProvider(LogType.login).future),
      throwsA(isA<loading.Error>()),
    );
    expect(requests, isEmpty);
    deviceSub.close();
    logSub.close();
  });

  test('服务端缺少列表时归一化为空列表', () async {
    final deviceSub = container.listen(loginDevicesProvider, (_, _) {});
    final logSub = container.listen(logTableProvider(LogType.exp), (_, _) {});
    await dispatched(2);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    requests[1].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    expect(await container.read(loginDevicesProvider.future), isEmpty);
    expect(await container.read(logTableProvider(LogType.exp).future), isEmpty);
    deviceSub.close();
    logSub.close();
  });

  testWidgets('切号加载时不显示前一账号的表格', (tester) async {
    container.dispose();
    final pending = <Completer<List<LogRow>>>[];
    container = ProviderContainer(
      overrides: [
        logTableProvider(LogType.login).overrideWith((ref) {
          ref.watch(mainAccountProvider);
          final reply = Completer<List<LogRow>>();
          pending.add(reply);
          return reply.future;
        }),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LogPage(type: LogType.login)),
      ),
    );
    expect(pending, hasLength(1));
    pending[0].complete([
      [(3, 'old-time'), (2, 'old-ip'), (3, 'old-geo')],
    ]);
    await tester.pumpAndSettle();
    expect(find.text('old-time'), findsOneWidget);
    final second = login(200, 'second');
    Accounts.accountMode[AccountType.main.index] = second;
    await Accounts.refresh();
    await tester.pump();
    await tester.pump();
    expect(find.text('old-time'), findsNothing);
    expect(pending, hasLength(2));
    pending[1].complete([
      [(3, 'new-time'), (2, 'new-ip'), (3, 'new-geo')],
    ]);
    await tester.pumpAndSettle();
    expect(find.text('new-time'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
