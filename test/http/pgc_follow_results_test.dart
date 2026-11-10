import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture-csrf'}),
    null,
    null,
  );
  final requests = <RequestOptions>[];
  Object? body;
  bool fail = false;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (fail) {
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
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = account;
    fail = false;
  });
  tearDownAll(() => Request.dio.close(force: true));
  final writes = <Future<LoadingState<String>> Function()>[
    () => VideoHttp.pgcAdd(seasonId: 1, account: account),
    () => VideoHttp.pgcDel(seasonId: 1, account: account),
    () => VideoHttp.pgcUpdate(seasonId: '1,2', status: 3, account: account),
  ];

  test('追番写入保留业务拒绝、待确认和原账号，关闭自动重试', () async {
    body = {'code': -403, 'message': '拒绝操作'};
    for (final write in writes) {
      final error = await write() as Error;
      expect(error.code, -403);
      expect(error, isNot(isA<UnknownResult>()));
      expect(requests.last.extra['account'], same(account));
      expect(requests.last.extra['noRetry'], isTrue);
      expect((requests.last.data as Map)['csrf'], 'fixture-csrf');
    }
    fail = true;
    for (final write in writes) {
      final error = await write() as UnknownResult;
      expect(error.cause, isA<DioException>());
      expect(error.stackTrace, isNotNull);
    }
    fail = false;
    body = {'message': 'missing-code'};
    for (final write in writes) {
      expect(await write(), isA<UnknownResult>());
    }
  });

  test('提示回显可缺失或损坏，已确认成功仍返回可读文案', () async {
    for (final result in [
      null,
      'invalid',
      {'toast': 1},
      {'toast': ''},
    ]) {
      body = {'code': 0, 'result': result};
      for (final write in writes) {
        expect((await write()).data, isNotEmpty);
      }
    }
    body = {
      'code': 0,
      'result': {'toast': '已更新'},
    };
    expect((await writes.first()).data, '已更新');
  });

  test('追番目标或分组不完整时不分发写请求', () async {
    for (final result in [
      await VideoHttp.pgcAdd(),
      await VideoHttp.pgcDel(seasonId: 0),
      await VideoHttp.pgcUpdate(seasonId: '1,null', status: 1),
      await VideoHttp.pgcUpdate(seasonId: '1', status: -1),
    ]) {
      expect(result, isA<Error>());
      expect(result, isNot(isA<UnknownResult>()));
    }
    expect(requests, isEmpty);
  });
}
