import 'dart:convert';

import 'package:dio/dio.dart';

/// 只实现设置备份所需的 Basic Auth、MKCOL、PUT 和 GET。
/// 路径始终相对 endpoint，不列目录、不解析 XML，也不访问应用主请求客户端。
class WebDavSettingsClient {
  WebDavSettingsClient({
    required Uri endpoint,
    required String username,
    required String password,
    Dio? dio,
  }) : _endpoint = endpoint,
       _dio = dio ?? Dio(),
       _authorization = username.isEmpty && password.isEmpty
           ? null
           : 'Basic ${base64Encode(utf8.encode('$username:$password'))}' {
    _dio.options.connectTimeout = _timeout;
    if (!const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw ArgumentError('WebDAV 地址必须为不含认证信息、查询和片段的 HTTP(S) 地址');
    }
    if (username.contains(':')) {
      throw ArgumentError('WebDAV Basic Auth 用户名不能包含冒号');
    }
  }

  final Uri _endpoint;
  final Dio _dio;
  final String? _authorization;
  static const _timeout = Duration(seconds: 12);

  List<String> _segments(String path) {
    final segments = path.split('/').where((part) => part.isNotEmpty).toList();
    if (segments.any((part) => part == '.' || part == '..') ||
        path.contains(r'\')) {
      throw ArgumentError('WebDAV 路径不能包含 .、.. 或反斜杠');
    }
    return segments;
  }

  Uri _uri(List<String> segments, {bool collection = false}) =>
      _endpoint.replace(
        pathSegments: [
          ..._endpoint.pathSegments.where((part) => part.isNotEmpty),
          ...segments,
          if (collection) '',
        ],
      );

  Future<void> ensureDirectory(String directory) async {
    final segments = _segments(directory);
    for (var length = 1; length <= segments.length; length++) {
      await _request(
        'MKCOL',
        _uri(segments.sublist(0, length), collection: true),
        accepted: const {201, 405},
      );
    }
  }

  Future<void> write(String path, List<int> bytes) async {
    // PUT 本身替换资源，不能先 DELETE：上传失败时仍应保留服务器上的旧备份。
    await _request(
      'PUT',
      _uri(_segments(path)),
      data: Stream<List<int>>.value(bytes),
      headers: {
        Headers.contentTypeHeader: 'application/json; charset=utf-8',
        Headers.contentLengthHeader: bytes.length,
      },
      accepted: const {200, 201, 204},
    );
  }

  Future<List<int>> read(String path) async {
    final response = await _request('GET', _uri(_segments(path)));
    return response.data!;
  }

  Future<Response<List<int>>> _request(
    String method,
    Uri uri, {
    Object? data,
    Map<String, Object>? headers,
    Set<int> accepted = const {200},
  }) async {
    try {
      return await _dio.requestUri<List<int>>(
        uri,
        data: data,
        options: Options(
          method: method,
          headers: {
            'accept-charset': 'utf-8',
            if (_authorization != null) 'authorization': _authorization,
            ...?headers,
          },
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          responseType: ResponseType.bytes,
          // 不跟随跳转，避免在备份请求中向其他地址重放认证信息和设置数据。
          followRedirects: false,
          validateStatus: (status) => accepted.contains(status),
        ),
      );
    } on DioException catch (error) {
      // 不向 UI 暴露 Dio 的请求头、响应正文或可能含凭据的完整 URL。
      throw WebDavRequestException(method, error.response?.statusCode);
    }
  }

  /// 客户端只供单次设置操作使用，操作结束后关闭连接池，不跨操作缓存客户端。
  void close() => _dio.close(force: true);
}

class WebDavRequestException implements Exception {
  const WebDavRequestException(this.method, this.statusCode);

  final String method;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'WebDAV $method 网络请求未完成'
      : 'WebDAV $method 失败（HTTP $statusCode）';
}
