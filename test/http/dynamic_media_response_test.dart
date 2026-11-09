import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  final requests = <RequestOptions>[];
  Object? body;
  var failTransport = false;
  late Directory directory;
  late File image;
  setUpAll(() async {
    GStorage.setting = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.video = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
    directory = await Directory.systemTemp.createTemp('pili-dynamic-media-');
    image = await File('${directory.path}/fixture.png').writeAsBytes([1, 2, 3]);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
    failTransport = false;
    body = null;
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await image.delete();
    await directory.delete();
  });

  test('动态删除的明确拒绝和待确认结果均通过返回值交付', () async {
    body = {'code': -403, 'message': '拒绝删除'};
    expect(
      (await MsgHttp.removeDynamic(
        account: original,
        dynIdStr: '1',
      ) as Error).code,
      -403,
    );
    body = {'code': '0'};
    expect(
      await MsgHttp.removeDynamic(account: original, dynIdStr: '1'),
      isA<UnknownResult>(),
    );
    failTransport = true;
    final uncertain = await MsgHttp.removeDynamic(
      account: original,
      dynIdStr: '1',
    ) as UnknownResult;
    expect(uncertain.cause, isA<DioException>());
    failTransport = false;
    body = {'code': 0};
    expect(await MsgHttp.removeDynamic(dynIdStr: '1'), isA<Success<void>>());
    for (final request in requests) {
      expect(request.extra['noRetry'], isTrue);
      expect(request.extra['account'], same(original));
      expect(request.queryParameters['csrf'], original.csrf);
    }
  });

  test('图片上传区分本地读取失败、业务拒绝和已发送后的不完整结果', () async {
    final missing =
        await MsgHttp.uploadBfs(path: '${directory.path}/missing.png') as Error;
    expect(missing, isNot(isA<UnknownResult>()));
    expect(missing.cause, isA<FileSystemException>());
    expect(missing.stackTrace, isNotNull);
    expect(requests, isEmpty);
    body = {'code': -403, 'message': '上传被拒绝'};
    expect((await MsgHttp.uploadBfs(path: image.path) as Error).code, -403);
    body = {
      'code': 0,
      'data': {'image_url': 'https://example.invalid/image.png'},
    };
    expect(await MsgHttp.uploadBfs(path: image.path), isA<UnknownResult>());
    failTransport = true;
    expect(await MsgHttp.uploadBfs(path: image.path), isA<UnknownResult>());
  });

  test('读取图片期间切号仍沿用发起账号，合法上传元数据完整交付', () async {
    body = {
      'code': 0,
      'data': {
        'image_url': 'https://example.invalid/image.png',
        'image_width': 1,
        'image_height': 2,
      },
    };
    final pending = MsgHttp.uploadBfs(path: image.path);
    Accounts.accountMode[AccountType.main.index] = replacement;
    final result = await pending;
    expect(result.data.imageWidth, 1);
    expect(result.data.imageHeight, 2);
    expect(requests.single.extra['account'], same(original));
    expect(requests.single.extra['noRetry'], isTrue);
    final fields = Map.fromEntries((requests.single.data as FormData).fields);
    expect(fields['csrf'], original.csrf);
  });
}
