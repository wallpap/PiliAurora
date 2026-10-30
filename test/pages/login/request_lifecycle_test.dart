import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/login/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  late _Controller controller;

  setUpAll(() async {
    GStorage.setting = await Hive.openBox('login-test', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox(
      'login-cache-test',
      bytes: Uint8List(0),
    );
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
    controller = _Controller()..onStart();
  });
  tearDown(() {
    if (!controller.isClosed) controller.onDelete();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await GStorage.setting.close();
    await GStorage.localCache.close();
  });

  testWidgets('二维码申请失败显示错误并允许重新申请', (tester) async {
    final first = controller.refreshQRCode();
    await _flush(tester);
    adapter.reply(0, {'code': -1, 'message': '模拟失败'});
    await _flush(tester);
    await first;
    expect(controller.codeInfo.value, isA<Error>());
    final retry = controller.refreshQRCode();
    await _flush(tester);
    adapter.qr(1, 'retry');
    await _flush(tester);
    await retry;
    expect(controller.codeInfo.value.data.authCode, 'retry');
    controller.onDelete();
  });

  testWidgets('二维码刷新后旧响应不能覆盖新二维码', (tester) async {
    final first = controller.refreshQRCode();
    await _flush(tester);
    final second = controller.refreshQRCode();
    await _flush(tester);
    adapter.qr(1, 'new');
    await _flush(tester);
    adapter.qr(0, 'old');
    await _flush(tester);
    await Future.wait([first, second]);
    expect(controller.codeInfo.value.data.authCode, 'new');
    controller.onDelete();
  });

  testWidgets('离开扫码标签后迟到的成功轮询不会保存账号', (tester) async {
    controller.tabController.index = 2;
    await _flush(tester);
    adapter.qr(0, 'first');
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    expect(adapter.pending, hasLength(2));
    controller.tabController.index = 0;
    adapter.reply(1, {
      'code': 0,
      'data': {
        'cookie_info': {'cookies': <Object>[]},
      },
    });
    await _flush(tester);
    expect(controller.savedAccounts, 0);
    expect(controller.qrCodeTimer!.isActive, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(adapter.pending, hasLength(2));
  });

  testWidgets('关闭控制器后二维码申请不创建定时器', (tester) async {
    final request = controller.refreshQRCode();
    await _flush(tester);
    controller.onDelete();
    adapter.qr(0, 'late');
    await _flush(tester);
    await request;
    expect(controller.qrCodeTimer, isNull);
  });

  testWidgets('轮询异常停止请求，避免持续重试', (tester) async {
    controller.tabController.index = 2;
    await _flush(tester);
    adapter.qr(0, 'first');
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    adapter.reply(1, {'message': '模拟网络错误'});
    await _flush(tester);
    expect(controller.qrCodeTimer!.isActive, isFalse);
    expect(controller.qrCodeLeftTime.value, 0);
    await tester.pump(const Duration(seconds: 10));
    expect(adapter.pending, hasLength(2));
  });

  testWidgets('短信双击及冷却期调用只发送一次并在倒计时结束释放', (tester) async {
    await _mount(tester);
    controller.telTextController.text = '10000000000';
    final request = controller.sendSmsCode();
    await controller.sendSmsCode();
    await _flush(tester);
    expect(adapter.pending, hasLength(1));
    adapter.reply(0, {
      'code': 0,
      'data': {'recaptcha_url': '', 'captcha_key': 'synthetic'},
    });
    await _flush(tester);
    await request;
    expect(controller.smsSending.value, isFalse);
    expect(controller.smsSendCooldown.value, 60);
    await controller.sendSmsCode();
    expect(adapter.pending, hasLength(1));
    await tester.pump(const Duration(seconds: 60));
    expect(controller.smsSendCooldown.value, 0);
    expect(controller.smsSendCooldownTimer!.isActive, isFalse);
  });

  testWidgets('极验等待期间保持短信防重锁，成功后继续发送', (tester) async {
    await _mount(tester);
    controller.telTextController.text = '10000000000';
    controller.captcha = Completer<void>();
    final request = controller.sendSmsCode();
    await _flush(tester);
    adapter.reply(0, {
      'code': -105,
      'data': {
        'recaptcha_url': 'https://example.test/?recaptcha_token=fake&gee_gt=fake&gee_challenge=fake',
      },
    });
    await _flush(tester);
    expect(controller.smsSending.value, isTrue);
    await controller.sendSmsCode();
    expect(adapter.pending, hasLength(1));
    controller.captcha!.complete();
    await _flush(tester);
    expect(adapter.pending, hasLength(2));
    adapter.reply(1, {
      'code': 0,
      'data': {'recaptcha_url': '', 'captcha_key': 'synthetic'},
    });
    await _flush(tester);
    await request;
    expect(controller.smsSending.value, isFalse);
    expect(controller.smsSendCooldown.value, 60);
    controller.onDelete();
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('关闭控制器后短信迟到响应不启动倒计时', (tester) async {
    controller.telTextController.text = '10000000000';
    final request = controller.sendSmsCode();
    await _flush(tester);
    controller.onDelete();
    adapter.reply(0, {
      'code': 0,
      'data': {'recaptcha_url': '', 'captcha_key': 'synthetic'},
    });
    await _flush(tester);
    await request;
    expect(controller.smsSendCooldownTimer, isNull);
    expect(controller.smsSendCooldown.value, 0);
  });
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _mount(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
);

class _Controller extends LoginPageController {
  int savedAccounts = 0;
  Completer<void>? captcha;

  @override
  Future<void> setAccount(Map tokenInfo, List cookieInfo) async {
    savedAccounts++;
  }

  @override
  Future<void> getCaptcha(
    String gt,
    String challenge,
    FutureOr<void> Function() onSuccess,
  ) async {
    await captcha!.future;
    await onSuccess();
  }
}

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];

  void reply(int index, Map<String, dynamic> data) => pending[index].complete(
    ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    ),
  );

  void qr(int index, String code) => reply(index, {
    'code': 0,
    'data': {'auth_code': code, 'url': 'https://example.test/$code'},
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final response = Completer<ResponseBody>();
    pending.add(response);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}
