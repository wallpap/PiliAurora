import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/controlled_interceptor.dart';
import '../support/memory_box.dart';

class _CaptchaObserver extends NavigatorObserver {
  Map<String, dynamic>? result;
  int shown = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute) return;
    shown++;
    // 在原生 WebView 构建前提供导航结果，测试实际协调流程与取消路径。
    scheduleMicrotask(() => navigator!.removeRoute(route, result));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  const registration = {
    'code': 0,
    'data': {
      'token': 'token',
      'geetest': {'gt': 'gt', 'challenge': 'challenge'},
    },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(requests.clear);
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> mount(WidgetTester tester, _CaptchaObserver observer) =>
      tester.pumpWidget(
        GetMaterialApp(
          navigatorObservers: [observer],
          builder: FlutterSmartDialog.init(),
          home: const Scaffold(),
        ),
      );
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(ready(), isTrue);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('注册响应不完整时不给 WebView 错误参数，显示可操作提示', (tester) async {
    final observer = _CaptchaObserver();
    await mount(tester, observer);
    var completed = false;
    var calls = 0;
    final operation =
        RequestUtils.validate(
          'voucher',
          (_) {
            calls++;
          },
          account: account,
          isCurrent: () => true,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': 0, 'data': {}});
    await until(tester, () => completed);
    await operation;
    await tester.pump();
    expect(observer.shown, 0);
    expect(calls, 0);
    expect(find.text('验证响应未能确认，请重新打开验证'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('取消验证不提交校验请求，也不调用成功回调', (tester) async {
    final observer = _CaptchaObserver();
    await mount(tester, observer);
    var completed = false;
    var calls = 0;
    final operation =
        RequestUtils.validate(
          'voucher',
          (_) {
            calls++;
          },
          account: account,
          isCurrent: () => true,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(registration);
    await until(tester, () => completed);
    await operation;
    expect(observer.shown, 1);
    expect(requests, hasLength(1));
    expect(calls, 0);
    await finish(tester);
  });

  testWidgets('成功校验只调用一次回调，并等待回调实际完成', (tester) async {
    final observer = _CaptchaObserver()
      ..result = {
        'geetest_challenge': 'challenge',
        'geetest_seccode': 'seccode',
        'geetest_validate': 'proof',
      };
    await mount(tester, observer);
    final callback = Completer<void>();
    var calls = 0;
    var completed = false;
    String? verifiedId;
    final operation =
        RequestUtils.validate(
          'voucher',
          (id) {
            verifiedId = id;
            calls++;
            return callback.future;
          },
          account: account,
          isCurrent: () => true,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(registration);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {'is_valid': 1, 'grisk_id': 'verified-id'},
    });
    await until(tester, () => calls == 1);
    expect(verifiedId, 'verified-id');
    expect(completed, isFalse);
    callback.complete();
    await until(tester, () => completed);
    await operation;
    expect(calls, 1);
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('验证返回缺少证明字段时不向服务器提交不完整结果', (tester) async {
    final observer = _CaptchaObserver()
      ..result = {'geetest_challenge': 'challenge'};
    await mount(tester, observer);
    var completed = false;
    var calls = 0;
    final operation =
        RequestUtils.validate(
          'voucher',
          (_) {
            calls++;
          },
          account: account,
          isCurrent: () => true,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(registration);
    await until(tester, () => completed);
    await operation;
    expect(calls, 0);
    expect(requests, hasLength(1));
    expect(find.text('验证结果不完整，请重新打开验证'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('明确验证拒绝给出中文提示，不触发成功回调', (tester) async {
    final observer = _CaptchaObserver()
      ..result = {
        'geetest_challenge': 'challenge',
        'geetest_seccode': 'seccode',
        'geetest_validate': 'proof',
      };
    await mount(tester, observer);
    var completed = false;
    var calls = 0;
    final operation =
        RequestUtils.validate(
          'voucher',
          (_) {
            calls++;
          },
          account: account,
          isCurrent: () => true,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(registration);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {'is_valid': 0},
    });
    await until(tester, () => completed);
    await operation;
    expect(calls, 0);
    expect(find.text('验证未通过，请重试'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('成功后的消费者异常沿原 Future 交付，不重新发送校验', (tester) async {
    final observer = _CaptchaObserver()
      ..result = {
        'geetest_challenge': 'challenge',
        'geetest_seccode': 'seccode',
        'geetest_validate': 'proof',
      };
    await mount(tester, observer);
    final cause = StateError('synthetic callback failure');
    Object? failure;
    var completed = false;
    final observed =
        RequestUtils.validate(
          'voucher',
          (_) => Future<void>.error(cause),
          account: account,
          isCurrent: () => true,
        ).then<void>(
          (_) {
            completed = true;
          },
          onError: (Object error) {
            failure = error;
            completed = true;
          },
        );
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(registration);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {'is_valid': 1, 'grisk_id': 'verified-id'},
    });
    await until(tester, () => completed);
    await observed;
    expect(failure, same(cause));
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('切号失效后的注册结果不再打开验证或调用成功回调', (tester) async {
    final observer = _CaptchaObserver();
    await mount(tester, observer);
    var current = true;
    var completed = false;
    final operation =
        RequestUtils.validate(
          'voucher',
          (_) {
            fail('旧操作不应继续');
          },
          account: account,
          isCurrent: () => current,
        )..then<void>((_) {
          completed = true;
        });
    await until(tester, () => requests.length == 1);
    current = false;
    requests[0].reply.complete(registration);
    await until(tester, () => completed);
    await operation;
    expect(observer.shown, 0);
    expect(requests, hasLength(1));
    await finish(tester);
  });
}
