import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 下载正文的接收超时不计入消费者暂停源流的时间。
class DownloadResponseAdapter implements HttpClientAdapter {
  DownloadResponseAdapter(this._delegate);

  static const pauseAwareTimeoutKey = 'downloadPauseAwareReceiveTimeout';
  final HttpClientAdapter _delegate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final timeout = options.receiveTimeout;
    // 先由原适配器完成连接和响应头读取，保留这两个阶段的超时。
    final response = await _delegate.fetch(
      options,
      requestStream,
      cancelFuture,
    );
    if (options.extra[pauseAwareTimeoutKey] == true &&
        options.responseType == ResponseType.stream &&
        timeout != null &&
        timeout > Duration.zero) {
      // Dio 的正文计时器在背压期间不会停止。仅此请求改用暂停感知的
      // Stream.timeout；原流仍由 Dio 负责取消和错误传递。
      options.receiveTimeout = Duration.zero;
      response.stream = response.stream.timeout(
        timeout,
        onTimeout: (sink) {
          sink
            ..addError(
              DioException.receiveTimeout(
                timeout: timeout,
                requestOptions: options,
              ),
            )
            ..close();
        },
      );
    }
    return response;
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);
}
