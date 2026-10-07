import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/settings/webdav_client.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];
  int Function(RequestOptions) status = (_) => 200;
  List<int> response = [];
  bool closed = false;
  bool forceClosed = false;
  bool failConnection = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(await requestStream?.expand((chunk) => chunk).toList() ?? []);
    if (failConnection) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
        message: 'password=fixture-server-secret',
      );
    }
    return ResponseBody.fromBytes(
      response,
      status(options),
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
    forceClosed = force;
  }
}

void main() {
  late _Adapter adapter;
  late WebDavSettingsClient client;

  setUp(() {
    adapter = _Adapter();
    client = WebDavSettingsClient(
      endpoint: Uri.parse('https://example.test/remote.php/dav/files/user/'),
      username: 'fixture-user',
      password: 'fixture-password',
      dio: Dio()..httpClientAdapter = adapter,
    );
  });

  tearDown(() => client.close());

  final failure = isA<WebDavRequestException>();

  test('MKCOL creates nested directories in order and accepts existing collections', () async {
    adapter.status = (request) => request.uri.path.endsWith('app/') ? 201 : 405;
    await client.ensureDirectory('/backups//app/');
    expect(adapter.requests.map((request) => request.method), [
      'MKCOL',
      'MKCOL',
    ]);
    expect(adapter.requests.map((request) => request.uri.path), [
      '/remote.php/dav/files/user/backups/',
      '/remote.php/dav/files/user/backups/app/',
    ]);
    expect(adapter.bodies, [[], []]);
  });

  for (final status in [401, 403, 409, 500, 302]) {
    test(
      'MKCOL stops at HTTP $status rather than hiding directory errors',
      () async {
        adapter.status = (_) => status;
        await expectLater(
          client.ensureDirectory('parent/child'),
          throwsA(
            failure.having((error) => error.statusCode, 'status', status),
          ),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  test('UTF-8 Basic Auth is scoped to the isolated client', () async {
    await client.read('settings.json');
    expect(
      adapter.requests.single.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('fixture-user:fixture-password'))}',
    );
    expect(adapter.requests.single.headers['accept-charset'], 'utf-8');
    expect(Dio().options.headers.containsKey('authorization'), isFalse);
  });

  test('empty credentials omit the Authorization header', () async {
    final anonymous = WebDavSettingsClient(
      endpoint: Uri.parse('https://example.test/dav'),
      username: '',
      password: '',
      dio: Dio()..httpClientAdapter = adapter,
    );
    try {
      await anonymous.read('settings.json');
      expect(
        adapter.requests.single.headers.containsKey('authorization'),
        isFalse,
      );
    } finally {
      anonymous.close();
    }
  });

  test(
    'segments are encoded as names, never as URL queries or fragments',
    () async {
      await client.read('/备份/settings #%?.json');
      final uri = adapter.requests.single.uri;
      expect(uri.pathSegments.last, 'settings #%?.json');
      expect(uri.pathSegments, [
        'remote.php',
        'dav',
        'files',
        'user',
        '备份',
        'settings #%?.json',
      ]);
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
      expect(uri.toString(), contains('%23%25%3F.json'));
    },
  );

  test(
    'literal encoded-looking names are not decoded into traversal',
    () async {
      await client.read('%2e%2e/settings.json');
      expect(adapter.requests.single.uri.pathSegments, contains('%2e%2e'));
      expect(adapter.requests.single.uri.toString(), contains('%252e%252e'));
    },
  );

  for (final path in [
    '../settings.json',
    'safe/./settings.json',
    r'safe\settings.json',
  ]) {
    test(
      'rejects escaping or ambiguous path $path before making a request',
      () async {
        await expectLater(client.read(path), throwsArgumentError);
        expect(adapter.requests, isEmpty);
      },
    );
  }

  for (final status in [200, 201, 204]) {
    test('PUT accepts HTTP $status and sends exact raw JSON bytes', () async {
      adapter.status = (_) => status;
      final bytes = utf8.encode('{"标题":"设置","enabled":true}');
      await client.write('backup/settings.json', bytes);
      final request = adapter.requests.single;
      expect(request.method, 'PUT');
      expect(request.headers[Headers.contentLengthHeader], bytes.length);
      expect(request.contentType, 'application/json; charset=utf-8');
      expect(adapter.bodies.single, bytes);
    });
  }

  test('a failed upload never requests DELETE of the old backup', () async {
    adapter
      ..response = utf8.encode('password=fixture-response-secret')
      ..status = (_) => 500;
    await expectLater(client.write('settings.json', [1, 2]), throwsA(failure));
    expect(adapter.requests.map((request) => request.method), ['PUT']);
  });

  test(
    'GET returns exact bytes even when the server advertises JSON',
    () async {
      adapter.response = utf8.encode('{"标题":"恢复"}');
      expect(await client.read('settings.json'), adapter.response);
      expect(adapter.requests.single.responseType, ResponseType.bytes);
      expect(adapter.requests.single.method, 'GET');
    },
  );

  test('GET accepts empty resources without inventing bytes', () async {
    expect(await client.read('settings.json'), isEmpty);
  });

  test('HTTP errors expose method and status but never response data or credentials', () async {
    adapter
      ..response = utf8.encode('fixture-response-secret')
      ..status = (_) => 404;
    await expectLater(
      client.read('settings.json'),
      throwsA(
        failure.having(
          (error) => error.toString(),
          'safe error',
          'WebDAV GET 失败（HTTP 404）',
        ),
      ),
    );
  });

  test('connection failures do not expose the underlying Dio error', () async {
    adapter.failConnection = true;
    await expectLater(
      client.read('settings.json'),
      throwsA(
        failure.having(
          (error) => error.toString(),
          'safe error',
          'WebDAV GET 网络请求未完成',
        ),
      ),
    );
  });

  test(
    'redirects are rejected and all three request phases have timeouts',
    () async {
      adapter.status = (_) => 307;
      await expectLater(client.write('settings.json', []), throwsA(failure));
      final request = adapter.requests.single;
      expect(request.followRedirects, isFalse);
      expect(request.connectTimeout, const Duration(seconds: 12));
      expect(request.sendTimeout, const Duration(seconds: 12));
      expect(request.receiveTimeout, const Duration(seconds: 12));
      expect(adapter.requests, hasLength(1));
    },
  );

  test('close releases the owned connection pool', () {
    client.close();
    expect(adapter.closed, isTrue);
    expect(adapter.forceClosed, isTrue);
  });

  for (final endpoint in [
    'file:///backup',
    'ftp://example.test/dav',
    '/dav',
    'https://user:fixture-password@example.test/dav',
    'https://example.test/dav?token=fixture-token',
    'https://example.test/dav#fragment',
  ]) {
    test('rejects invalid or credential-bearing endpoint', () {
      expect(
        () => WebDavSettingsClient(
          endpoint: Uri.parse(endpoint),
          username: '',
          password: '',
        ),
        throwsArgumentError,
      );
    });
  }

  test('rejects colon in Basic Auth usernames', () {
    expect(
      () => WebDavSettingsClient(
        endpoint: Uri.parse('https://example.test/dav'),
        username: 'user:name',
        password: '',
      ),
      throwsArgumentError,
    );
  });

  test(
    'real Dio round-trips settings against an isolated loopback WebDAV server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      var stored = <int>[];
      final subscription = server.listen((request) async {
        methods.add(request.method);
        final bytes = await request.expand((chunk) => chunk).toList();
        switch (request.method) {
          case 'MKCOL':
            request.response.statusCode = 201;
          case 'PUT':
            stored = bytes;
            request.response.statusCode = 204;
          case 'GET':
            request.response.headers.contentType = ContentType.json;
            request.response.add(stored);
        }
        await request.response.close();
      });
      final local = WebDavSettingsClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/dav/'),
        username: '',
        password: '',
      );
      try {
        final payload = utf8.encode('{"name":"本地测试"}');
        await local.ensureDirectory('backup');
        await local.write('backup/settings.json', payload);
        expect(await local.read('backup/settings.json'), payload);
        expect(methods, ['MKCOL', 'PUT', 'GET']);
      } finally {
        local.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}
