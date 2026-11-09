import 'dart:core' hide Error;
import 'dart:core' as core show Error;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';

Response<dynamic> response(Object? body, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: '/synthetic'),
      statusCode: status,
      data: body,
    );

void main() {
  test('领域解码器决定空数据语义，明确业务成功可返回 void', () {
    expect(
      decodeApiResponse<int?>(
        response({'code': 0, 'data': null}),
        kind: ApiCallKind.query,
        decode: (body) => body['data'] as int?,
      ).data,
      isNull,
    );
    expect(
      decodeApiResponse<void>(
        response({'code': 0}),
        kind: ApiCallKind.mutation,
        decode: (_) {},
      ),
      isA<Success<void>>(),
    );
  });

  test('业务失败保留状态码，message 缺失时使用 msg 或错误码兜底', () {
    for (final body in <Map<String, dynamic>>[
      {'code': -403, 'message': ' ', 'msg': 'access denied'},
      {'code': -403, 'message': 42},
    ]) {
      final result = decodeApiResponse<void>(
        response(body),
        kind: ApiCallKind.mutation,
        decode: (_) => fail('不能解析拒绝响应的数据'),
      ) as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.code, -403);
      expect(
        result.toString(),
        body.containsKey('msg') ? 'access denied' : contains('-403'),
      );
    }
  });

  test('缺少合法状态码时查询返回格式错误，写入返回结果待确认', () {
    for (final body in [
      null,
      [],
      'private raw body',
      {},
      {'code': '0'},
    ]) {
      for (final kind in ApiCallKind.values) {
        final result = decodeApiResponse<void>(
          response(body),
          kind: kind,
          decode: (_) => fail('不能解析损坏响应的数据'),
        ) as Error;
        expect(result is UnknownResult, kind == ApiCallKind.mutation);
        expect(result.cause, isA<FormatException>());
        expect(result.stackTrace, isNotNull);
        expect(result.toString(), isNot(contains('private')));
      }
    }
  });

  test('直接读取业务错误文案也不会暴露凭据', () {
    final result = decodeApiResponse<void>(
      response({'code': -1, 'message': 'token=synthetic-secret'}),
      kind: ApiCallKind.query,
      decode: (_) {},
    ) as Error;
    expect(result.errMsg, isNot(contains('synthetic-secret')));
  });

  test('解码失败保留同一个原因与堆栈，写入不提示直接重试', () {
    final cause = StateError('unstructured private body');
    final stack = StackTrace.fromString('synthetic decoder stack');
    for (final kind in ApiCallKind.values) {
      final result = decodeApiResponse<int>(
        response({'code': 0, 'data': {}}),
        kind: kind,
        decode: (_) => core.Error.throwWithStackTrace(cause, stack),
      ) as Error;
      expect(result.cause, same(cause));
      expect(result.stackTrace, same(stack));
      expect(result is UnknownResult, kind == ApiCallKind.mutation);
      expect(result.toString(), isNot(contains('private')));
    }
  });

  test('HTTP 失败不能被正文中的成功码掩盖', () {
    final result = decodeApiResponse<void>(
      response({'code': 0}, status: 500),
      kind: ApiCallKind.mutation,
      decode: (_) {},
    );
    expect(result, isA<UnknownResult>());
  });

  test('HTTP 错误或 Cookie 保存失败保留明确业务拒绝，其他写入异常待确认', () async {
    final stack = StackTrace.current;
    for (final code in [-101, 0]) {
      final raw = response({'code': code, 'msg': 'rejected'}, status: 403);
      final cause = DioException(
        requestOptions: raw.requestOptions,
        response: raw,
        error: const AccountCookiePersistenceException('private cookie value'),
      );
      final result = await decodeApiException(
        cause,
        stack,
        kind: ApiCallKind.mutation,
      );
      expect(result.cause, same(cause));
      expect(result.stackTrace, same(stack));
      expect(result is UnknownResult, code == 0);
      if (code != 0) expect(result.code, code);
    }
  });

  test('查询传输失败保留原始异常，用户提示不包含底层异常正文', () async {
    final stack = StackTrace.current;
    final cause = DioException(
      requestOptions: RequestOptions(path: '/synthetic'),
      error: 'unstructured private response',
    );
    final result = await decodeApiException(
      cause,
      stack,
      kind: ApiCallKind.query,
    );
    expect(result, isNot(isA<UnknownResult>()));
    expect(result.cause, same(cause));
    expect(result.stackTrace, same(stack));
    expect(result.toString(), isNot(contains('private')));
    expect(await AccountManager.dioError(cause), isNot(contains('private')));
  });
}
