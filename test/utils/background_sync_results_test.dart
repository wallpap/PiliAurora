import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart' as result;
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import '../support/controlled_http_adapter.dart';
import '../support/memory_box.dart';

class _CookiePlatform extends InAppWebViewPlatform {
  final cookies = _Cookies();

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;
}

class _Cookies extends PlatformCookieManager {
  _Cookies()
    : super.implementation(const PlatformCookieManagerCreationParams());

  final events = <String>[];
  Future<bool> Function() onSet = () async => true;
  Future<bool> Function() onDelete = () async => true;

  @override
  Future<bool> setCookie({
    required WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    HTTPCookieSameSitePolicy? sameSite,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) {
    if (name == 'DedeUserID') events.add('set:$value');
    return onSet();
  }

  @override
  Future<bool> deleteAllCookies() {
    events.add('delete');
    return onDelete();
  }
}

class _HistoryCache extends MemoryBox<dynamic> {
  Future<void> Function()? beforeWrite;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (key == LocalCacheKey.historyPause) await beforeWrite?.call();
    await super.put(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _CookiePlatform();
  final cookies = platform.cookies;
  late ControlledHttpAdapter adapter;
  late List<Account> previousAccounts;
  final cache = _HistoryCache();
  final profile = MemoryBox<UserInfoData>();

  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture'}),
    null,
    null,
  );
  void select(Account value) {
    Accounts.accountMode[AccountType.main.index] = value;
    Accounts.accountMode[AccountType.heartbeat.index] = value;
  }

  setUpAll(() {
    InAppWebViewPlatform.instance = platform;
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = cache;
    GStorage.userInfo = profile;
    Request();
    Request.dio.interceptors.clear();
    Get.testMode = true;
  });
  setUp(() {
    previousAccounts = List.of(Accounts.accountMode);
    cache.data.clear();
    cache.beforeWrite = null;
    profile.data.clear();
    adapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = adapter;
    cookies
      ..events.clear()
      ..onSet = (() async => true)
      ..onDelete = (() async => true);
    select(account(123));
    Get.put(AccountService());
  });
  tearDown(() {
    adapter.close();
    Accounts.accountMode.setAll(0, previousAccounts);
    Get.reset();
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('Cookie 原生拒绝与异常沿 Future 返回，失败后队列仍可继续', () async {
    cookies.onSet = () async => false;
    await expectLater(
      LoginUtils.setWebCookie(),
      throwsA(
        isA<result.Error>().having(
          (error) => error.errMsg,
          'message',
          '网页 Cookie 同步失败，请重试',
        ),
      ),
    );
    final failure = StateError('fixture native failure');
    cookies.onSet = () async => throw failure;
    await expectLater(LoginUtils.setWebCookie(), throwsA(same(failure)));
    cookies.onSet = () async => true;
    expect(await LoginUtils.setWebCookie(), isTrue);
  });

  test('Cookie 批次串行交接，排队的旧账号不分发，迟到结果失效', () async {
    final started = Completer<void>();
    final release = Completer<bool>();
    cookies.onSet = () {
      if (!started.isCompleted) started.complete();
      return release.future;
    };
    final old = LoginUtils.setWebCookie();
    await started.future;
    final stale = LoginUtils.setWebCookie();
    select(account(456));
    final current = LoginUtils.setWebCookie();
    await Future<void>.delayed(Duration.zero);
    expect(cookies.events, ['set:123']);
    cookies.onSet = () async => true;
    release.complete(true);
    expect(await old, isFalse);
    expect(await stale, isFalse);
    expect(await current, isTrue);
    expect(cookies.events, ['set:123', 'set:456']);
  });

  test('登出清理等待旧 Cookie 完成，原生拒绝后仍能同步新账号', () async {
    final started = Completer<void>();
    final release = Completer<bool>();
    cookies.onSet = () {
      if (!started.isCompleted) started.complete();
      return release.future;
    };
    final old = LoginUtils.setWebCookie();
    await started.future;
    select(AnonymousAccount());
    cookies.onDelete = () async => false;
    final logout = expectLater(
      LoginUtils.onLogoutMain(),
      throwsA(
        isA<result.Error>().having(
          (error) => error.errMsg,
          'message',
          '网页 Cookie 清理失败，请重试',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(cookies.events, ['set:123']);
    release.complete(true);
    expect(await old, isFalse);
    await logout;
    select(account(456));
    cookies.onSet = () async => true;
    expect(await LoginUtils.setWebCookie(), isTrue);
    expect(cookies.events, ['set:123', 'delete', 'set:456']);
  });

  test('排队的登出清理在新账号接管后失效', () async {
    final started = Completer<void>();
    final release = Completer<bool>();
    cookies.onSet = () {
      if (!started.isCompleted) started.complete();
      return release.future;
    };
    final old = LoginUtils.setWebCookie();
    await started.future;
    select(AnonymousAccount());
    final logout = LoginUtils.onLogoutMain();
    select(account(456));
    final current = LoginUtils.setWebCookie();
    cookies.onSet = () async => true;
    release.complete(true);
    expect(await old, isFalse);
    await logout;
    expect(await current, isTrue);
    expect(cookies.events, ['set:123', 'set:456']);
  });

  test('历史同步等待持久化完成，并沿同一 Future 交付写入失败', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final failure = StateError('fixture storage failure');
    cache.beforeWrite = () {
      started.complete();
      return release.future;
    };
    var finished = false;
    final operation = RequestUtils.syncHistoryStatus().whenComplete(() {
      finished = true;
    });
    final assertion = expectLater(operation, throwsA(same(failure)));
    await adapter.waitForRequests(1);
    adapter.json(0, {'code': 0, 'data': true});
    await started.future;
    expect(finished, isFalse);
    release.completeError(failure);
    await assertion;
    expect(cache.data, isEmpty);
  });

  testWidgets('登录成功不被后台 Cookie 与历史缓存失败覆盖', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    cookies.onSet = () async => throw StateError('fixture native failure');
    final historyFailed = Completer<void>();
    cache.beforeWrite = () {
      historyFailed.complete();
      throw StateError('fixture storage failure');
    };
    Future<void> until(bool Function() ready) async {
      final deadline = tester.binding.clock.now().add(
        const Duration(seconds: 3),
      );
      while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(ready(), isTrue);
    }

    var loggedIn = false;
    final login = LoginUtils.onLoginMain()..then((_) => loggedIn = true);
    await until(() => adapter.requests.length == 1);
    adapter.json(0, {
      'code': 0,
      'data': {
        'isLogin': true,
        'face': 'fixture-face',
        'money': 9,
        'mid': 123,
      },
    });
    await until(() => loggedIn && adapter.requests.length == 2);
    await login;
    adapter.json(1, {'code': 0, 'data': true});
    await until(() => historyFailed.isCompleted);
    await tester.pump();
    expect(Get.find<AccountService>().isLogin.value, isTrue);
    expect(Pref.userInfoCache?.mid, 123);
    expect(cache.data, isEmpty);
    final dismissal = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
