import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  late RequestOptions captured;

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(Response(requestOptions: options, data: body));
          },
        ),
      );
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('二维码非对象响应和缺失字段返回可重试错误', () async {
    for (final value in [
      null,
      '<html>unavailable</html>',
      {'code': 0},
      {
        'code': 0,
        'data': {'auth_code': 'code', 'url': 42},
      },
    ]) {
      body = value;
      final result = await LoginHttp.getHDcode();
      expect(result, isA<Error>());
      expect(result.toString(), contains('重试'));
    }
  });

  test('登录公钥缺失或字段类型错误不交给页面强制转换', () async {
    for (final data in [
      null,
      {},
      {'key': 42},
      {'key': 'key', 'hash': 42},
    ]) {
      body = {'code': 0, 'data': data};
      final result = await LoginHttp.getWebKey();
      expect(result.isSuccess, isFalse);
      expect(result.message, isNotEmpty);
      expect(result.code, isNull);
    }
  });

  test('短信响应缺失验证码凭据不会报告发送成功', () async {
    for (final data in [
      null,
      {},
      {'recaptcha_url': ''},
    ]) {
      body = {'code': 0, 'data': data};
      final result = await LoginHttp.sendSmsCode(cid: 86, tel: 'synthetic');
      expect(result.isSuccess, isFalse);
      expect(result.code, isNull);
      expect(captured.extra['noRetry'], isTrue);
    }
  });

  test('短信风控保留验证地址，正常发送提供明确成功结果', () async {
    for (final code in [0, -105]) {
      body = {
        'code': code,
        'data': {'recaptcha_url': 'https://example.test/challenge'},
      };
      final result = await LoginHttp.sendSmsCode(cid: 86, tel: 'synthetic');
      expect(result.isSuccess, isFalse);
      expect(result.code, code);
      expect(result.data['recaptcha_url'], 'https://example.test/challenge');
      expect(result.message, isNotEmpty);
    }
    body = {
      'code': 0,
      'data': {'recaptcha_url': '', 'captcha_key': 'synthetic'},
    };
    final result = await LoginHttp.sendSmsCode(cid: 86, tel: 'synthetic');
    expect(result.isSuccess, isTrue);
    expect(result.data['captcha_key'], 'synthetic');
  });

  test('轮询保留等待扫码的业务码，缺少身份信息不误判为登录成功', () async {
    body = {'code': 86039, 'message': '尚未确认'};
    final waiting = await LoginHttp.codePoll('synthetic');
    expect(waiting.isSuccess, isFalse);
    expect(waiting.code, 86039);
    expect(waiting.message, '尚未确认');
    expect(captured.extra['noRetry'], isTrue);

    body = {'code': 0, 'data': {}};
    final malformed = await LoginHttp.codePoll('synthetic');
    expect(malformed.isSuccess, isFalse);
    expect(malformed.code, isNull);
  });

  test('令牌交换缺少身份信息时返回失败且不自动重放', () async {
    body = {
      'code': 0,
      'data': {'token_info': {}},
    };
    final result = await LoginHttp.oauth2AccessToken(code: 'synthetic');
    expect(result.isSuccess, isFalse);
    expect(result.message, isNotEmpty);
    expect(captured.extra['noRetry'], isTrue);
  });

  test('损坏公钥返回明确失败，不向页面抛加密异常', () async {
    final password = await LoginHttp.loginByPwd(
      username: 'synthetic',
      password: 'synthetic',
      key: 'invalid',
      salt: '',
    );
    final sms = await LoginHttp.loginBySms(
      captchaKey: 'synthetic',
      tel: 'synthetic',
      code: 'synthetic',
      cid: 86,
      key: 'invalid',
    );
    expect(password.isSuccess, isFalse);
    expect(sms.isSuccess, isFalse);
    expect(password.message, contains('加密失败'));
    expect(sms.message, contains('加密失败'));
  });
}
