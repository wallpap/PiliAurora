import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/match.dart';
import 'package:pili_aurora/http/music.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  bool failTransport = false;
  final requests = <RequestOptions>[];
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Accounts.accountMode[AccountType.main.index] = account;
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
  });
  setUp(() {
    requests.clear();
    body = null;
    failTransport = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('音乐名称必需，封面和评论元数据缺失仍可展示详情', () async {
    body = {
      'code': 0,
      'data': {'music_title': 'sample'},
    };
    final result = await MusicHttp.bgmDetail('track');
    expect(result.data.musicTitle, 'sample');
    expect(result.data.mvCover, isNull);
    expect(result.data.musicComment, isNull);
    expect(requests.single.extra['account'], same(account));
    for (final data in [
      null,
      {},
      {'music_title': ''},
      {'music_title': 1},
    ]) {
      body = {'code': 0, 'data': data};
      final error = await MusicHttp.bgmDetail('track') as Error;
      expect(error.cause, isNotNull);
      expect(error.stackTrace, isNotNull);
    }
  });

  test('推荐视频保留可空与空列表语义，损坏列表交付为错误', () async {
    body = {'code': 0, 'data': null};
    expect((await MusicHttp.bgmRecommend('track')).data, isNull);
    body = {
      'code': 0,
      'data': {'list': []},
    };
    expect((await MusicHttp.bgmRecommend('track')).data, isEmpty);
    body = {
      'code': 0,
      'data': {'list': 'invalid'},
    };
    expect((await MusicHttp.bgmRecommend('track') as Error).cause, isNotNull);
  });

  test('赛事内容缺失属于正常空数据，损坏包体或对象属于错误', () async {
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect((await MatchHttp.matchInfo(1)).data, isNull);
    body = {
      'code': 0,
      'data': {
        'contest': {'game_stage': 'final'},
      },
    };
    expect((await MatchHttp.matchInfo(1)).data!.gameStage, 'final');
    for (final data in [
      null,
      [],
      'private body',
      {'contest': []},
    ]) {
      body = {'code': 0, 'data': data};
      final result = await MatchHttp.matchInfo(1) as Error;
      expect(result.cause, isNotNull);
      expect(result.toString(), isNot(contains('private')));
    }
  });

  test('各接口保留业务码；点赞的传输失败保持待确认', () async {
    body = {'code': -403, 'message': '拒绝请求'};
    for (final invoke in <Future<LoadingState<dynamic>> Function()>[
      () => MusicHttp.bgmDetail('track'),
      () => MusicHttp.bgmRecommend('track'),
      () => MatchHttp.matchInfo(1),
      () => MusicHttp.wishUpdate('track', false),
    ]) {
      final error = await invoke() as Error;
      expect(error.code, -403);
      expect(error, isNot(isA<UnknownResult>()));
    }
    failTransport = true;
    final result = await MusicHttp.wishUpdate('track', false) as UnknownResult;
    expect(result.cause, isA<DioException>());
    expect(requests.last.extra['account'], same(account));
    expect(requests.last.extra['noRetry'], isTrue);
    expect((requests.last.data as Map)['csrf'], 'synthetic-csrf');
  });

  test('空音乐标识在分发请求前被拒绝', () async {
    expect(await MusicHttp.bgmDetail(''), isA<Error>());
    expect(await MusicHttp.bgmRecommend(''), isA<Error>());
    final write = await MusicHttp.wishUpdate('', false);
    expect(write, isA<Error>());
    expect(write, isNot(isA<UnknownResult>()));
    expect(requests, isEmpty);
  });
}
