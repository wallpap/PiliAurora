import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const diskError = FileSystemException('synthetic storage failure');
  late _Jar jar;
  late LoginAccount account;
  late Dio client;
  late _Adapter adapter;

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
  });
  setUp(() {
    jar = _Jar(diskError);
    account = LoginAccount(jar, null, null);
    adapter = _Adapter();
    client = Dio(BaseOptions(baseUrl: 'https://api.bilibili.com'))
      ..httpClientAdapter = adapter;
    client.interceptors.addAll([
      RetryInterceptor(client, 2, 0),
      AccountManager(),
    ]);
  });
  tearDown(() => client.close(force: true));

  Future<DioException> requestFailure() async {
    try {
      await client.post<dynamic>(
        '/fixture',
        options: Options(extra: {'account': account}),
      );
    } on DioException catch (error) {
      return error;
    }
    throw StateError('请求应返回异常');
  }

  test('Cookie 保存失败通过请求 Future 返回，保留响应且不重放写请求', () async {
    final error = await requestFailure();
    expect(error.error, isA<AccountCookiePersistenceException>());
    expect(
      (error.error as AccountCookiePersistenceException).cause,
      same(diskError),
    );
    expect(error.response?.statusCode, 200);
    expect(error.response?.data, {'code': 0});
    expect(error.stackTrace.toString(), isNotEmpty);
    expect(await AccountManager.dioError(error), contains('账号状态保存失败'));
    expect(adapter.requests, 1);
    expect(jar.saves, 1);
  });

  test('HTTP 失败同时遇到 Cookie 保存失败时保留原始状态和错误类型', () async {
    adapter.status = 500;
    final error = await requestFailure();
    expect(error.type, DioExceptionType.badResponse);
    expect(error.response?.statusCode, 500);
    expect(error.error, isNot(isA<AccountCookiePersistenceException>()));
    expect(adapter.requests, 1);
    expect(jar.saves, 1);
  });

  test('没有 Cookie 更新的响应不要求持久化', () async {
    adapter.cookie = false;
    final result = await client.post<dynamic>(
      '/fixture',
      options: Options(extra: {'account': account}),
    );
    expect(result.statusCode, 200);
    expect(jar.saves, 0);
  });
}

class _Jar extends DefaultCookieJar {
  _Jar(this.failure) {
    domainCookies.addAll(
      BiliCookieJar.fromJson({
        'DedeUserID': '123',
        'bili_jct': 'synthetic',
      }).domainCookies,
    );
  }
  final Object failure;
  int saves = 0;

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) {
    saves++;
    return Future.error(failure, StackTrace.current);
  }
}

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  int status = 200;
  bool cookie = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '{"code":0}',
      status,
      headers: {
        'content-type': ['application/json'],
        if (cookie) 'set-cookie': ['fixture=value; Path=/'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
