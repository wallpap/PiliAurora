import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/validate.dart';
import 'package:pili_aurora/models/login/gaia_result.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  bool failTransport = false;
  final requests = <RequestOptions>[];
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() {
    requests.clear();
    failTransport = false;
    body = null;
  });
  tearDownAll(() => Request.dio.close(force: true));
  Future<LoadingState<GaiaVerificationResult>> verify({
    String validate = 'proof',
  }) => ValidateHttp.gaiaVgateValidate(
    account: account,
    challenge: 'challenge',
    seccode: 'seccode',
    token: 'token',
    validate: validate,
  );

  test('注册返回完整且不可空的挑战参数，账号和 CSRF 固定', () async {
    body = {
      'code': 0,
      'data': {
        'token': 'token',
        'geetest': {'gt': 'gt', 'challenge': 'challenge'},
      },
    };
    final challenge = (await ValidateHttp.gaiaVgateRegister(
      'voucher',
      account: account,
    )).data;
    expect(challenge.token, 'token');
    expect(challenge.gt, 'gt');
    expect(challenge.challenge, 'challenge');
    expect(requests.single.extra['account'], same(account));
    expect(requests.single.extra['noRetry'], isTrue);
    expect(requests.single.queryParameters['csrf'], 'synthetic-csrf');
  });

  test('缺少 token、gt 或 challenge 的注册结果不能作为成功使用', () async {
    for (final data in [
      null,
      {},
      {
        'token': 'token',
        'geetest': {'gt': 'gt'},
      },
      {
        'token': ' ',
        'geetest': {'gt': 'gt', 'challenge': 'challenge'},
      },
    ]) {
      body = {'code': 0, 'data': data};
      final result = await ValidateHttp.gaiaVgateRegister(
        'voucher',
        account: account,
      ) as UnknownResult;
      expect(result.cause, isNotNull);
      expect(result.stackTrace, isNotNull);
    }
  });

  test('通过验证必须携带非空 ID，明确拒绝与损坏结果分开交付', () async {
    body = {
      'code': 0,
      'data': {'is_valid': 1, 'grisk_id': 'verified-id'},
    };
    expect(
      (await verify()).data,
      isA<GaiaVerified>().having((v) => v.riskId, 'risk ID', 'verified-id'),
    );
    body = {
      'code': 0,
      'data': {'is_valid': 0},
    };
    expect((await verify()).data, isA<GaiaRejected>());
    for (final data in [
      null,
      {},
      {'is_valid': 1},
      {'is_valid': 1, 'grisk_id': ''},
      {'is_valid': '1'},
    ]) {
      body = {'code': 0, 'data': data};
      expect(await verify(), isA<UnknownResult>());
    }
  });

  test('未发出请求的空参数明确失败，业务拒绝保留代码', () async {
    expect(
      await ValidateHttp.gaiaVgateRegister('', account: account),
      isNot(isA<UnknownResult>()),
    );
    expect(await verify(validate: ''), isNot(isA<UnknownResult>()));
    expect(requests, isEmpty);
    body = {'code': -412, 'message': '验证过期'};
    final result = await verify() as Error;
    expect(result, isNot(isA<UnknownResult>()));
    expect(result.code, -412);
  });

  test('在途传输失败保持待确认，保留原始异常并关闭重试', () async {
    failTransport = true;
    final result = await verify() as UnknownResult;
    expect(result.cause, isA<DioException>());
    expect(result.stackTrace, isNotNull);
    expect(requests, hasLength(1));
    expect(requests.single.extra['noRetry'], isTrue);
  });
}
