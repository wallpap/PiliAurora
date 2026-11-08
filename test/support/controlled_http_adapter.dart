import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 挂起响应并按实际请求到达唤醒测试，不依赖固定次数的事件队列轮询。
class ControlledHttpAdapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  final requests = <RequestOptions>[];
  final _arrivals = StreamController<void>.broadcast(sync: true);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    await stream?.drain<void>();
    final response = Completer<ResponseBody>();
    requests.add(options);
    pending.add(response);
    _arrivals.add(null);
    return response.future;
  }

  Future<void> waitForRequests(int count) async {
    if (pending.length >= count) return;
    await _arrivals.stream
        .firstWhere((_) => pending.length >= count)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw TimeoutException('等待 $count 个请求，实际 ${pending.length} 个'),
        );
  }

  void json(int index, Object value) => pending[index].complete(
    ResponseBody.fromString(
      jsonEncode(value),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    ),
  );

  @override
  void close({bool force = false}) => unawaited(_arrivals.close());
}
