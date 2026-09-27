import 'package:dio/dio.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

class DiagnosticHttpInterceptor extends Interceptor {
  DiagnosticHttpInterceptor({Diagnostics? diagnostics})
    : _diagnostics = diagnostics ?? Diagnostics.instance;

  final Diagnostics _diagnostics;
  static const _key = 'piliDiagnosticOperation';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // 重试可能复用 RequestOptions；先结束上一轮，避免活动请求计数泄漏。
    (options.extra.remove(_key) as TraceOperation?)?.finish(error: 'retry');
    options.extra[_key] = _diagnostics.begin(
      'http',
      options.method,
      details: {
        'host': options.uri.host,
        // 不记录查询参数、请求头、请求体或响应体。
        'path': options.uri.path,
      },
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    (response.requestOptions.extra.remove(_key) as TraceOperation?)?.finish(
      details: {
        'status': response.statusCode,
        'declaredResponseBytes': int.tryParse(
          response.headers.value('content-length') ?? '',
        ),
      },
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final operation = err.requestOptions.extra.remove(_key) as TraceOperation?;
    operation?.finish(
      error: err.type.name,
      details: {'status': err.response?.statusCode},
    );
    if (operation == null) {
      _diagnostics.log(
        DiagnosticLogLevel.error,
        'http',
        '请求失败',
        details: {
          'host': err.requestOptions.uri.host,
          'path': err.requestOptions.uri.path,
          'method': err.requestOptions.method,
          'type': err.type.name,
          'status': err.response?.statusCode,
        },
      );
    }
    handler.next(err);
  }
}
