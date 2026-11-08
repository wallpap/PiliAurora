import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在拦截器边界控制响应，保留请求参数，供账号和分页生命周期测试使用。
class ControlledInterceptor extends Interceptor {
  ControlledInterceptor({this.headers});

  final Headers? headers;
  final requests = <({RequestOptions options, Completer<dynamic> reply})>[];
  final _arrivals = StreamController<void>.broadcast(sync: true);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final reply = Completer<dynamic>();
    requests.add((options: options, reply: reply));
    _arrivals.add(null);
    handler.resolve(
      Response(
        requestOptions: options,
        data: await reply.future,
        headers: headers,
      ),
    );
  }

  Future<void> waitForRequests(int count) async {
    if (requests.length < count) {
      await _arrivals.stream
          .firstWhere((_) => requests.length >= count)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw TimeoutException('等待 $count 个请求，实际 ${requests.length} 个'),
          );
    }
    expect(requests, hasLength(count));
  }

  Future<void> close() => _arrivals.close();
}
