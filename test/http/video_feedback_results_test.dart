import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final main = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1'}),
    'main-key',
    null,
  );
  final recommend = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '2'}),
    'recommend-key',
    null,
  );
  final requests = <RequestOptions>[];
  bool fail = false;
  Object? body;
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
            if (fail) {
              handler.reject(
                DioException(requestOptions: options, type: .sendTimeout),
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
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.recommend.index] = recommend;
    requests.clear();
    body = {'code': 0};
    fail = false;
  });
  tearDownAll(() => Request.dio.close(force: true));
  final writes = <Future<LoadingState<void>> Function()>[
    () => VideoHttp.feedDislike(goto: 'av', id: 1, reasonId: 2),
    () => VideoHttp.feedDislikeCancel(goto: 'av', id: 1),
    () => VideoHttp.dislikeVideo(bvid: IdUtils.av2bv(1), type: true),
  ];

  test('GET 反馈及撤销也是写入，真实重试拦截器不重放超时请求', () async {
    fail = true;
    for (final write in writes) {
      final before = requests.length;
      final error = await write() as UnknownResult;
      expect(requests.length, before + 1);
      expect(error.cause, isA<DioException>());
      expect(error.stackTrace, isNotNull);
      expect(requests.last.extra['noRetry'], isTrue);
    }
    expect(requests.map((request) => request.method), ['GET', 'GET', 'POST']);
    expect(requests[0].extra['account'], same(recommend));
    expect(requests[1].extra['account'], same(recommend));
    expect(requests[2].extra['account'], same(main));
  });

  test('反馈保留拒绝码；空回显成功，损坏协议为待确认', () async {
    for (final write in writes) {
      body = {'code': -403, 'message': '拒绝反馈'};
      final rejected = await write() as Error;
      expect(rejected.code, -403);
      expect(rejected, isNot(isA<UnknownResult>()));
      body = {'code': 0};
      expect(await write(), isA<Success<void>>());
      body = {'message': 'private-body'};
      final uncertain = await write() as UnknownResult;
      expect(uncertain.toString(), isNot(contains('private-body')));
    }
  });

  test('缺少或冲突的反馈目标在分发前拒绝，撤销可不带原因', () async {
    for (final result in [
      await VideoHttp.feedDislike(goto: 'av', id: 1),
      await VideoHttp.feedDislike(
        goto: 'av',
        id: 1,
        reasonId: 1,
        feedbackId: 2,
      ),
      await VideoHttp.feedDislikeCancel(goto: '', id: 0),
      await VideoHttp.dislikeVideo(bvid: '', type: true),
    ]) {
      expect(result, isA<Error>());
      expect(result, isNot(isA<UnknownResult>()));
    }
    expect(requests, isEmpty);
    expect(await writes[1](), isA<Success<void>>());
  });
}
