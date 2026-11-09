import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';

void main() {
  late Dio client;
  var attempts = 0;
  var failUntil = 1;
  var type = DioExceptionType.sendTimeout;
  Object? cause;

  setUp(() {
    attempts = 0;
    failUntil = 1;
    type = DioExceptionType.sendTimeout;
    cause = null;
    client = Dio();
    client.interceptors.addAll([
      RetryInterceptor(client, 2, 0),
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts <= failUntil) {
            handler.reject(
              DioException(requestOptions: options, type: type, error: cause),
              true,
            );
          } else {
            handler.resolve(Response(requestOptions: options, data: 'ok'));
          }
        },
      ),
    ]);
  });
  tearDown(() => client.close(force: true));

  for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
    test('$method 默认不重放结果不确定的写请求', () async {
      await expectLater(
        client.request<dynamic>(
          'https://example.test/write',
          options: Options(method: method),
        ),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
    });
  }

  test('安全读取沿用有限重试预算', () async {
    for (final method in ['GET', 'HEAD', 'OPTIONS']) {
      attempts = 0;
      failUntil = 2;
      final result = await client.request<dynamic>(
        'https://example.test/read',
        options: Options(method: method),
      );
      expect(result.data, 'ok');
      expect(attempts, 3);
    }
    attempts = 0;
    failUntil = 99;
    await expectLater(
      client.get<dynamic>('https://example.test/read'),
      throwsA(isA<DioException>()),
    );
    expect(attempts, 3);
  });

  test('gRPC 读取显式选择可重试，noRetry 与流式响应继续禁止重试', () async {
    final result = await client.post<dynamic>(
      'https://example.test/read',
      options: Options(extra: {'noRetry': false}),
    );
    expect(result.data, 'ok');
    expect(attempts, 2);
    for (final options in [
      Options(extra: {'noRetry': true}),
      Options(responseType: ResponseType.stream),
    ]) {
      attempts = 0;
      await expectLater(
        client.get<dynamic>('https://example.test/read', options: options),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
    }
  });

  test('解析和程序错误不作为瞬时网络异常重试', () async {
    type = DioExceptionType.unknown;
    for (final error in [
      const FormatException('invalid response'),
      StateError('invalid decoder state'),
    ]) {
      cause = error;
      attempts = 0;
      await expectLater(
        client.get<dynamic>('https://example.test/read'),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
    }
    cause = const SocketException('transient network failure');
    attempts = 0;
    final result = await client.get<dynamic>('https://example.test/read');
    expect(result.data, 'ok');
    expect(attempts, 2);
  });
}
