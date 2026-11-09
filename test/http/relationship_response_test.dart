import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/black.dart';
import 'package:pili_aurora/http/danmaku_block.dart';
import 'package:pili_aurora/http/fan.dart';
import 'package:pili_aurora/http/follow.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
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
  DioExceptionType? failureType;
  DioException? lastFailure;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failureType case final type?) {
              final error = lastFailure = DioException(
                requestOptions: options,
                type: type,
                error: 'private transport body',
              );
              handler.reject(error, true);
            } else {
              handler.resolve(Response(data: body, requestOptions: options));
            }
          },
        ),
      );
  });
  tearDownAll(() => Request.dio.close(force: true));
  setUp(() {
    requests.clear();
    body = null;
    failureType = null;
    lastFailure = null;
  });

  final queries = <String, Future<LoadingState<Object?>> Function()>{
    '关注': () => FollowHttp.followings(account: account, vmid: 1, pn: 1),
    '粉丝': () => FanHttp.fans(account: account, vmid: 1, pn: 1),
    '黑名单': () => BlackHttp.blackList(account: account, pn: 1),
    '屏蔽规则': () => DanmakuFilterHttp.danmakuFilter(account: account),
  };
  for (final entry in queries.entries) {
    test('${entry.key}查询把损坏数据交付为可诊断错误，账号绑定不变', () async {
      for (final data in [
        null,
        [],
        'private body',
        {'code': 0, 'data': []},
      ]) {
        body = data;
        final result = await entry.value() as Error;
        expect(result, isNot(isA<UnknownResult>()));
        expect(result.cause, isNotNull);
        expect(result.stackTrace, isNotNull);
        expect(result.toString(), isNot(contains('private')));
        expect(requests.last.method, 'GET');
        expect(requests.last.extra['account'], same(account));
      }
    });
  }

  test('关注和粉丝保留风控业务码及现有可读提示', () async {
    body = {'code': -352, 'message': 'raw rejection'};
    for (final query in [queries['关注']!, queries['粉丝']!]) {
      final result = await query() as Error;
      expect(result.code, -352);
      expect(result.toString(), '风控校验失败，请检查登录状态');
    }
  });

  test('损坏规则列表不伪装为空列表，新增规则必须有有效 ID 与匹配类型', () async {
    body = {
      'code': 0,
      'data': {'rule': 'invalid'},
    };
    final query =
        await DanmakuFilterHttp.danmakuFilter(account: account) as Error;
    expect(query.cause, isA<FormatException>());
    for (final rule in [
      {'id': 0, 'type': 0, 'filter': 'sample'},
      {'id': 42, 'type': 2, 'filter': 'sample'},
    ]) {
      body = {'code': 0, 'data': rule};
      expect(
        await DanmakuFilterHttp.danmakuFilterAdd(
          filter: 'sample',
          type: 0,
          account: account,
        ),
        isA<UnknownResult>(),
      );
    }
  });

  test('新增规则确认成功后返回服务端 ID，删除和排序允许空 data', () async {
    body = {
      'code': 0,
      'data': {'id': 42, 'type': 0, 'filter': 'sample'},
    };
    final rule = await DanmakuFilterHttp.danmakuFilterAdd(
      filter: 'sample',
      type: 0,
      account: account,
    );
    expect(rule.data.id, 42);
    expect((requests.last.data as Map)['csrf'], 'synthetic-csrf');
    body = {'code': 0};
    expect(
      await DanmakuFilterHttp.danmakuFilterDel(ids: 42, account: account),
      isA<Success<void>>(),
    );
    expect(
      await FollowHttp.sortFollowTag(account: account, tagids: '1,2'),
      isA<Success<void>>(),
    );
  });

  test('无法确认的写入返回 UnknownResult，保留原因且不会自动重放', () async {
    failureType = DioExceptionType.connectionError;
    final result = await Request().requestApi<void>(
      '/synthetic/mutation',
      kind: ApiCallKind.mutation,
      options: Options(extra: {'noRetry': false}),
      decode: (_) {},
    ) as UnknownResult;
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.extra['noRetry'], isTrue);
    expect(result.cause, same(lastFailure));
    expect(result.stackTrace, isNotNull);
    expect(result.toString(), contains('核对'));
  });

  test('已取消的写入不分发请求，返回明确取消而非结果待确认', () async {
    final token = CancelToken()..cancel('private cancel reason');
    final result = await Request().requestApi<void>(
      '/synthetic/mutation',
      kind: ApiCallKind.mutation,
      decode: (_) {},
      cancelToken: token,
    ) as Error;
    expect(requests, isEmpty);
    expect(result, isNot(isA<UnknownResult>()));
    expect(result.cause, same(token.cancelError));
    expect(result.toString(), '请求已取消');
  });

  test('查询继续使用已声明的网络重试，最终失败保留实际原因', () async {
    failureType = DioExceptionType.connectionError;
    final result = await queries['关注']!() as Error;
    expect(requests, hasLength(3));
    expect(result, isNot(isA<UnknownResult>()));
    expect(result.cause, same(lastFailure));
  });

  test('POST 查询和 GET 写入仍按操作语义选择重试策略', () async {
    body = {'code': 0, 'data': 42};
    for (final kind in ApiCallKind.values) {
      final method = kind == ApiCallKind.query ? 'POST' : 'GET';
      final result = await Request().requestApi<int>(
        '/synthetic/operation',
        kind: kind,
        options: Options(method: method),
        decode: (body) => body['data'] as int,
      );
      expect(result.data, 42);
      expect(requests.last.method, method);
      expect(requests.last.extra['noRetry'], kind == ApiCallKind.mutation);
    }
  });

  test('新增规则成功码后的损坏结果保持待确认，业务拒绝保留错误码', () async {
    body = {'code': 0, 'data': {}};
    expect(
      await DanmakuFilterHttp.danmakuFilterAdd(
        filter: 'sample',
        type: 0,
        account: account,
      ),
      isA<UnknownResult>(),
    );
    body = {'code': -400, 'msg': 'invalid rule'};
    final result = await DanmakuFilterHttp.danmakuFilterAdd(
      filter: 'sample',
      type: 0,
      account: account,
    ) as Error;
    expect(result, isNot(isA<UnknownResult>()));
    expect(result.code, -400);
    expect(result.toString(), 'invalid rule');
  });
}
