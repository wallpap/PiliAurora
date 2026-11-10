import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/request_failure_policy.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  );
  late LoginAccount original;
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
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            Accounts.accountMode[AccountType.heartbeat.index] = account(
              'replacement',
            );
            if (fail) {
              handler.reject(
                DioException(requestOptions: options, type: .receiveTimeout),
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
    original = account('original');
    Accounts.accountMode[AccountType.heartbeat.index] = original;
    requests.clear();
    body = {'code': 0};
    fail = false;
  });
  tearDownAll(() => Request.dio.close(force: true));
  final reports = <String, Future<LoadingState<void>> Function()>{
    '直播进入': () => VideoHttp.roomEntryAction(roomId: 1),
    '文章历史': () => VideoHttp.historyReport(aid: 1, type: 5),
    '播放进度': () => VideoHttp.heartBeat(
      bvid: 'BV1xx',
      cid: 1,
      progress: 10,
      videoType: VideoType.ugc,
    ),
    '播放列表': () => VideoHttp.medialistHistory(desc: 0, oid: 1, upperMid: 2),
  };
  for (final entry in reports.entries) {
    test('${entry.key}成功不依赖正文，HTTP 与 CSRF 固定同一上报账号', () async {
      expect(await entry.value(), isA<Success<void>>());
      final options = requests.single;
      expect(options.extra['account'], same(original));
      expect(options.extra['noRetry'], true);
      expect(
        options.path == Api.roomEntryAction
            ? options.queryParameters['csrf']
            : (options.data as Map)['csrf'],
        'original',
      );
    });
    test('${entry.key}保留业务拒绝，损坏响应和超时待确认且不自动重发', () async {
      body = {'code': -403, 'message': '拒绝上报'};
      final rejected = await entry.value() as Error;
      expect(rejected.code, -403);
      expect(rejected, isNot(isA<UnknownResult>()));
      body = {};
      expect(await entry.value(), isA<UnknownResult>());
      fail = true;
      final count = requests.length;
      final unknown = await entry.value() as UnknownResult;
      expect(unknown.cause, isA<DioException>());
      expect(unknown.stackTrace, isNotNull);
      expect(requests, hasLength(count + 1));
      expect(isExpectedHttpFailure(unknown.cause! as DioException), true);
    });
  }
}
