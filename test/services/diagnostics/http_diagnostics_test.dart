import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/http_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Diagnostics diagnostics;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-http-diagnostics-');
    diagnostics = Diagnostics(processReader: () => {});
    await diagnostics.initialize(directory: directory);
  });
  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test('HTTP success and failure finish operations without copying request secrets', () async {
    await diagnostics.configure(tracing: true, level: DiagnosticLogLevel.debug);
    final dio = Dio()..httpClientAdapter = _TestHttpAdapter();
    dio.interceptors.add(DiagnosticHttpInterceptor(diagnostics: diagnostics));
    try {
      await dio.post<Object?>(
        'https://example.test/success?token=http-query-test',
        data: {'password': 'http-body-test'},
        options: Options(headers: {'Cookie': 'http-cookie-test'}),
      );
      await expectLater(
        dio.get<Object?>('https://example.test/failure'),
        throwsA(isA<DioException>()),
      );
      diagnostics.capture();
      final http = (diagnostics.latest!['operations'] as Map)['http'] as Map;
      expect(http['active'], 0);
      expect(http['completed'], 2);
      expect(http['errors'], 1);
      expect(diagnostics.recentLogs, hasLength(2));
      final records = jsonEncode(diagnostics.recentLogs);
      for (final secret in [
        'http-query-test',
        'http-body-test',
        'http-cookie-test',
      ]) {
        expect(records, isNot(contains(secret)));
      }
      await diagnostics.configure(level: DiagnosticLogLevel.error);
      await expectLater(
        dio.get<Object?>('https://example.test/failure'),
        throwsA(isA<DioException>()),
      );
      expect(diagnostics.recentLogs, hasLength(3));
    } finally {
      dio.close(force: true);
    }
  });

  test('HTTP retries do not leave an active operation behind', () async {
    await diagnostics.configure(tracing: true);
    final interceptor = DiagnosticHttpInterceptor(diagnostics: diagnostics);
    final options = RequestOptions(path: 'https://example.test/retry');
    interceptor
      ..onRequest(options, RequestInterceptorHandler())
      ..onRequest(options, RequestInterceptorHandler())
      ..onResponse(
        Response<Object?>(requestOptions: options, statusCode: 200),
        ResponseInterceptorHandler(),
      );
    diagnostics.capture();
    final http = (diagnostics.latest!['operations'] as Map)['http'] as Map;
    expect(http['active'], 0);
    expect(http['completed'], 2);
  });
}

class _TestHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/failure') {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json'],
        'content-length': ['2'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
