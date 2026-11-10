import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <RequestOptions>[];
  Object? body;
  bool fail = false;
  void Function(RequestOptions)? onRequest;
  final queries = <Future<LoadingState<Object?>> Function()>[
    () => VideoHttp.rcmdVideoList(ps: 20, freshIdx: 0),
    () => VideoHttp.rcmdVideoListApp(freshIdx: 0),
    () => VideoHttp.hotVideoList(pn: 1, ps: 20),
    () => VideoHttp.videoIntro(bvid: 'BV-test'),
    () => VideoHttp.relatedVideoList(bvid: 'BV-test'),
    () => VideoHttp.onlineTotal(bvid: 'BV-test', cid: 1),
    () => VideoHttp.playInfo(bvid: 'BV-test', cid: 1),
    () => VideoHttp.getRankVideoList(0),
    () => VideoHttp.pgcRankList(seasonType: 1),
    () => VideoHttp.pgcSeasonRankList(seasonType: 2),
    () => VideoHttp.getVideoNoteList(oid: 1, page: 1),
    VideoHttp.popularSeriesList,
    () => VideoHttp.popularSeriesOne(number: 1),
    () => VideoHttp.popularPrecious(page: 1),
    () => VideoHttp.tvPlayUrl(cid: 1, objectId: 1, playurlType: 1),
  ];
  LoginAccount account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-csrf'}),
    'fixture-$mid',
    null,
  );
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
            onRequest?.call(options);
            if (fail) {
              handler.reject(
                DioException(requestOptions: options, type: .connectionError),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() async {
    requests.clear();
    fail = false;
    onRequest = null;
    body = null;
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = account(type.index + 1);
    }
    await GStorage.localCache.putAll({
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'fixture-key',
    });
  });
  tearDownAll(() => Request.dio.close(force: true));
  test('15类视频查询保留拒绝码，非法响应和传输失败通过结果交付', () async {
    for (final query in queries) {
      body = {'code': -403, 'message': '拒绝查询'};
      final rejected = await query() as Error;
      expect(rejected.code, -403);
      body = {'code': 0, 'data': 'private malformed data', 'result': 1};
      final malformed = await query() as Error;
      expect(malformed.cause, isNotNull);
      expect(malformed.stackTrace, isNotNull);
      expect(malformed.toString(), isNot(contains('private malformed data')));
      fail = true;
      final transport = await query() as Error;
      expect(transport.cause, isA<DioException>());
      expect(transport, isNot(isA<UnknownResult>()));
      fail = false;
    }
  });
  test('推荐与榜单等列表保留已有空语义，损坏每周期数拒绝进入页面', () async {
    body = {
      'code': 0,
      'data': {'item': [], 'items': [], 'list': []},
      'result': {'list': []},
    };
    for (final query in [
      queries[0],
      queries[1],
      queries[2],
      queries[7],
      queries[8],
      queries[9],
      queries[11],
    ]) {
      expect((await query()).data, isEmpty);
    }
    body = {'code': 0, 'data': null, 'result': null};
    for (final query in [queries[4], queries[8], queries[9], queries[11]]) {
      expect(await query(), isA<Success<Object?>>());
      expect((await query()).data, isNull);
    }
    body = {
      'code': 0,
      'data': {
        'list': [<String, dynamic>{}],
      },
    };
    final invalid = await VideoHttp.popularSeriesList() as Error;
    expect(invalid.cause, isA<FormatException>());
  });
  test('签名等待期间固定发起账号，资料读取保留显式账号的禁重试约定', () async {
    final original = Accounts.get(AccountType.recommend);
    await GStorage.localCache.delete(LocalCacheKey.mixinKey);
    onRequest = (options) {
      if (options.path == Api.userInfo) {
        Accounts.accountMode[AccountType.recommend.index] = account(99);
        body = {
          'code': 0,
          'data': {
            'wbi_img': {
              'img_url':
                  'https://fixture.test/01234567890123456789012345678901.png',
              'sub_url':
                  'https://fixture.test/01234567890123456789012345678901.png',
            },
          },
        };
      } else {
        body = {
          'code': 0,
          'data': {'item': []},
        };
      }
    };
    expect((await queries.first()).isSuccess, isTrue);
    expect(requests.last.extra['account'], same(original));
    onRequest = null;
    body = {'code': -404};
    await VideoHttp.videoIntro(bvid: 'BV-test', account: original);
    expect(requests.last.extra['account'], same(original));
    expect(requests.last.extra['noRetry'], isTrue);
  });
  test('取消查询不分发，签名准备失败保留原始原因', () async {
    final token = CancelToken()..cancel();
    final cancelled = await VideoHttp.rcmdVideoList(
      ps: 20,
      freshIdx: 0,
      cancelToken: token,
    ) as Error;
    expect(cancelled.cause, isA<DioException>());
    expect(requests, isEmpty);
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      'invalid cached timestamp',
    );
    final failed = await VideoHttp.videoIntro(bvid: 'BV-test') as Error;
    expect(failed.cause, isA<TypeError>());
    expect(failed.stackTrace, isNotNull);
    expect(requests, isEmpty);
  });
}
