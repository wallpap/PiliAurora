import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member_profile.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/models/common/member/profile_type.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    'synthetic-access',
    null,
  );
  final requests = <RequestOptions>[];
  Object? body;
  bool failTransport = false;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
                true,
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() {
    requests.clear();
    failTransport = false;
    body = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('资料查询绑定账号，缺失或错误账号资料不冒充成功', () async {
    for (final data in [
      null,
      {},
      {'mid': 2},
      {'mid': 1, 'coins': 'bad'},
    ]) {
      body = {'code': 0, 'data': data};
      final result = await MemberProfileHttp.info(account);
      expect(result, isA<Error>());
      expect((result as Error).cause, isNotNull);
    }
    body = {
      'code': 0,
      'data': {'mid': 1, 'name': '测试', 'coins': 10},
    };
    expect((await MemberProfileHttp.info(account)).data.name, '测试');
    expect(requests.last.extra['account'], same(account));
    expect(requests.last.queryParameters['access_key'], 'synthetic-access');
  });

  test('资料写入保留业务拒绝；成功无回显有效，签名账号固定且禁重试', () async {
    body = {'code': -403, 'message': '修改被拒绝'};
    expect(
      (await MemberProfileHttp.update(
        account: account,
        type: ProfileType.sign,
        value: '草稿',
      )).toString(),
      '修改被拒绝',
    );
    body = {'code': 0};
    for (final type in ProfileType.values) {
      expect(
        (await MemberProfileHttp.update(
          account: account,
          type: type,
          value: 'value',
        )).isSuccess,
        true,
      );
      final request = requests.last;
      expect(request.extra['account'], same(account));
      expect(request.extra['noRetry'], true);
      expect((request.data as Map)['access_key'], 'synthetic-access');
      expect((request.data as Map)['sign'], isNotEmpty);
    }
  });

  test('写入损坏响应与断连均待确认，不自动重放', () async {
    body = {'private-response': 'secret'};
    final malformed = await MemberProfileHttp.update(
      account: account,
      type: ProfileType.uname,
      value: '昵称',
    ) as UnknownResult;
    expect(malformed.cause, isA<FormatException>());
    expect(malformed.stackTrace, isNotNull);
    expect(malformed.toString(), isNot(contains('secret')));
    failTransport = true;
    requests.clear();
    final disconnected = await MemberProfileHttp.update(
      account: account,
      type: ProfileType.uname,
      value: '昵称',
    );
    expect(disconnected, isA<UnknownResult>());
    expect(requests, hasLength(1));
  });

  test('头像准备失败属于本地错误，上传结果沿写入契约交付', () async {
    final directory = await Directory.systemTemp.createTemp('pili-profile-');
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}/avatar.png');
    final missing = await MemberProfileHttp.avatar(
      account: account,
      filePath: image.path,
    );
    expect(missing, isA<Error>());
    expect(missing, isNot(isA<UnknownResult>()));
    expect(requests, isEmpty);
    await image.writeAsBytes([1, 2, 3]);
    body = {'code': 0};
    expect(
      (await MemberProfileHttp.avatar(
        account: account,
        filePath: image.path,
      )).isSuccess,
      true,
    );
    expect(requests.single.extra['account'], same(account));
    expect(requests.single.extra['noRetry'], true);
    expect(requests.single.queryParameters['csrf'], 'synthetic-csrf');
    expect((requests.single.data as FormData).files.single.key, 'face');
  });
}
