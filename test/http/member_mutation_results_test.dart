import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  final requests = <RequestOptions>[];
  Object? body;
  bool failTransport = false;
  int? status;
  DioException? lastFailure;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            final response = Response(
              requestOptions: options,
              data: body,
              statusCode: status,
            );
            if (failTransport) {
              final error = lastFailure = DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                response: status == null ? null : response,
              );
              handler.reject(error, true);
            } else {
              handler.resolve(response);
            }
          },
        ),
      );
  });
  setUp(() {
    requests.clear();
    body = null;
    status = null;
    failTransport = false;
    lastFailure = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  final writes = <Future<LoadingState<dynamic>> Function()>[
    () => MemberHttp.specialAction(account: account, fid: 2),
    () => MemberHttp.specialAction(account: account, fid: 2, isAdd: false),
    () => MemberHttp.addUsers('2', '10', account: account),
    () => MemberHttp.createFollowTag('新分组', account: account),
    () => MemberHttp.updateFollowTag(10, '新名称', account: account),
    () => MemberHttp.delFollowTag(10, account: account),
  ];
  Future<LoadingState<void>> report() => MemberHttp.reportMember(
    2,
    account: account,
    reason: '1,3',
    reasonV2: 2,
  );

  test('成员写入保留业务拒绝和错误码', () async {
    body = {'code': -403, 'message': '拒绝请求'};
    for (final send in writes) {
      final failure = await send() as Error;
      expect(failure.code, -403);
      expect(failure.toString(), '拒绝请求');
      expect(failure, isNot(isA<UnknownResult>()));
    }
  });

  test('成员写入绑定同一账号和 CSRF，允许无需回显的成功', () async {
    body = {
      'code': 0,
      'data': {'tagid': 10},
    };
    for (final send in writes) {
      expect(await send(), isA<Success<dynamic>>());
      expect(requests.last.method, 'POST');
      expect(requests.last.extra['account'], same(account));
      expect(requests.last.extra['noRetry'], isTrue);
      expect((requests.last.data as Map)['csrf'], 'synthetic-csrf');
    }
  });

  test('成员写入损坏响应和断连交付待确认，保留原因且不重放', () async {
    body = {'message': 'private-response'};
    for (final send in writes) {
      final failure = await send() as UnknownResult;
      expect(failure.cause, isA<FormatException>());
      expect(failure.stackTrace, isNotNull);
      expect(failure.toString(), isNot(contains('private-response')));
    }
    requests.clear();
    failTransport = true;
    for (final send in writes) {
      final failure = await send() as UnknownResult;
      expect(failure.cause, same(lastFailure));
      expect(failure.stackTrace, isNotNull);
    }
    expect(requests, hasLength(writes.length));
  });

  test('新建分组必须返回正整数 ID，缺失和系统分组不会写入本地', () async {
    for (final data in [
      null,
      {},
      {'tagid': 0},
      {'tagid': -10},
      {'tagid': '10'},
    ]) {
      body = {'code': 0, 'data': data};
      final failure = await MemberHttp.createFollowTag(
        '新分组',
        account: account,
      ) as UnknownResult;
      expect(failure.cause, isA<FormatException>());
    }
    body = {
      'code': 0,
      'data': {'tagid': 42},
    };
    expect(
      (await MemberHttp.createFollowTag('新分组', account: account)).data,
      42,
    );
  });

  test('举报沿独立布尔协议返回结果，绑定账号且关闭重试', () async {
    body = {'status': true};
    expect(await report(), isA<Success<void>>());
    expect(requests.single.extra['account'], same(account));
    expect(requests.single.extra['noRetry'], isTrue);
    expect(requests.single.data, {
      'mid': 2,
      'reason': '1,3',
      'reason_v2': 2,
      'csrf': 'synthetic-csrf',
    });
    body = {'status': false, 'message': '举报被拒绝'};
    expect((await report()).toString(), '举报被拒绝');
    body = {'status': false};
    final failure = await report();
    expect(failure, isA<Error>());
    expect(failure, isNot(isA<UnknownResult>()));
    expect(failure.toString(), '举报失败，请稍后重试');
  });

  test('举报缺状态、冲突 HTTP 和传输失败均待确认，不自动重发', () async {
    for (final value in [
      null,
      {'code': 0},
      {'status': 'true'},
    ]) {
      body = value;
      final failure = await report() as UnknownResult;
      expect(failure.cause, isA<FormatException>());
    }
    body = {'status': true};
    status = 503;
    expect(await report(), isA<UnknownResult>());
    status = null;
    requests.clear();
    failTransport = true;
    final failure = await report() as UnknownResult;
    expect(failure.cause, same(lastFailure));
    expect(failure.stackTrace, isNotNull);
    expect(requests, hasLength(1));
  });

  test('举报 HTTP 错误中明确的拒绝不会丢失', () async {
    failTransport = true;
    status = 403;
    body = {'status': false, 'message': '拒绝举报'};
    final failure = await report() as Error;
    expect(failure, isNot(isA<UnknownResult>()));
    expect(failure.toString(), '拒绝举报');
    expect(failure.cause, same(lastFailure));
  });
}
