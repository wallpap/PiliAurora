import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture-csrf'}),
    'fixture-access',
    null,
  );
  final requests = <RequestOptions>[];
  Object? body;
  var failTransport = false;
  DioException? lastFailure;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox()
      ..data[LocalCacheKey.buvid] = 'fixture-buvid';
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failTransport) {
              final error = lastFailure = DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
              );
              handler.reject(error, true);
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() {
    requests.clear();
    body = null;
    failTransport = false;
    lastFailure = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('账号撤销和设备查询保留业务拒绝及错误码', () async {
    body = {'code': -403, 'message': '拒绝请求'};
    for (final result in [
      await LoginHttp.logout(account),
      await LoginHttp.loginDevices(account: account),
    ]) {
      final failure = result as Error;
      expect(failure.code, -403);
      expect(failure.toString(), '拒绝请求');
      expect(failure, isNot(isA<UnknownResult>()));
    }
  });

  test('撤销无需回显即可成功，断连和损坏响应待确认且不重放', () async {
    body = {'code': 0};
    expect(await LoginHttp.logout(account), isA<Success<void>>());
    expect(requests.single.extra['account'], same(account));
    expect(requests.single.extra['noRetry'], isTrue);
    expect(requests.single.data, {'biliCSRF': 'fixture-csrf'});
    body = {'message': 'private response'};
    final malformed = await LoginHttp.logout(account) as UnknownResult;
    expect(malformed.cause, isA<FormatException>());
    expect(malformed.stackTrace, isNotNull);
    expect(malformed.toString(), isNot(contains('private response')));
    requests.clear();
    failTransport = true;
    final failure = await LoginHttp.logout(account) as UnknownResult;
    expect(failure.cause, same(lastFailure));
    expect(failure.stackTrace, isNotNull);
    expect(requests, hasLength(1));
  });

  test('设备查询保留凭据绑定和可空列表，合法设备按字段解析', () async {
    for (final devices in [null, <Object>[]]) {
      body = {
        'code': 0,
        'data': {'devices': devices},
      };
      final result = await LoginHttp.loginDevices(account: account);
      expect(result.isSuccess, isTrue);
      expect(result.data.devices ?? [], isEmpty);
    }
    expect(requests.last.extra['account'], same(account));
    expect(requests.last.extra['noRetry'], isFalse);
    expect(requests.last.queryParameters['csrf'], 'fixture-csrf');
    expect(requests.last.queryParameters['access_key'], 'fixture-access');
    body = {
      'code': 0,
      'data': {
        'devices': [
          {'device_name': '设备', 'is_current_device': true},
        ],
      },
    };
    final devices = (await LoginHttp.loginDevices(account: account))
        .data
        .devices!;
    expect(devices.single.deviceName, '设备');
    expect(devices.single.isCurrentDevice, isTrue);
  });

  test('设备损坏列表或条目以可诊断错误交付，失败仍允许查询重试', () async {
    for (final data in [
      null,
      {'devices': 'private response'},
      {
        'devices': [null],
      },
      {
        'devices': [
          {'is_current_device': 1},
        ],
      },
    ]) {
      body = {'code': 0, 'data': data};
      final failure = await LoginHttp.loginDevices(account: account) as Error;
      expect(failure, isNot(isA<UnknownResult>()));
      expect(failure.cause, isNotNull);
      expect(failure.stackTrace, isNotNull);
      expect(failure.toString(), isNot(contains('private response')));
    }
    requests.clear();
    failTransport = true;
    final failure = await LoginHttp.loginDevices(account: account) as Error;
    expect(failure, isNot(isA<UnknownResult>()));
    expect(failure.cause, same(lastFailure));
    expect(requests, hasLength(3));
  });
}
