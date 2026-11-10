import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/subtitle_utils.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <RequestOptions>[];
  Object? body;
  DioException? lastError;
  bool fail = false;
  void Function(RequestOptions)? onRequest;
  final original = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1'}),
    null,
    null,
  );
  Future<LoadingState<Object?>> play() => VideoHttp.videoUrl(
    bvid: 'BV-test',
    cid: 1,
    qn: 80,
    epid: 1,
    tryLook: true,
    videoType: VideoType.ugc,
    language: 'ja',
    voiceBalance: true,
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
              final error = lastError = DioException(
                requestOptions: options,
                type: .receiveTimeout,
              );
              handler.reject(error);
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() async {
    Accounts.accountMode[AccountType.video.index] = original;
    requests.clear();
    lastError = null;
    fail = false;
    onRequest = null;
    body = null;
    await GStorage.localCache.putAll({
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'fixture-key',
    });
  });
  tearDownAll(() => Request.dio.close(force: true));
  test('网络或解析失败保留原因，不触发不相关的番剧协议回退', () async {
    fail = true;
    final failed = await play() as Error;
    expect(failed.cause, same(lastError));
    expect(requests.single.path, Api.ugcUrl);
    fail = false;
    requests.clear();
    body = {'code': 0, 'data': 'invalid payload'};
    final malformed = await play() as Error;
    expect(malformed.cause, isNotNull);
    expect(malformed.stackTrace, isNotNull);
    expect(requests.single.path, Api.ugcUrl);
  });
  test('业务拒绝允许回退，所有路径保留账号、语言和音量均衡参数', () async {
    onRequest = (options) {
      if (options.path == Api.ugcUrl) {
        body = {'code': -404};
        Accounts.accountMode[AccountType.video.index] = AnonymousAccount();
      } else {
        body = {
          'code': 0,
          'result': {
            'video_info': {'quality': 80},
            'play_view_business_info': {
              'user_status': {
                'watch_progress': {'current_watch_progress': 123},
              },
            },
          },
        };
      }
    };
    final result = await VideoHttp.videoUrl(
      bvid: 'BV-test',
      cid: 1,
      qn: 80,
      epid: 1,
      tryLook: true,
      videoType: VideoType.ugc,
      language: 'ja',
      voiceBalance: true,
    );
    expect(result.data.quality, 80);
    expect(result.data.lastPlayTime, 123);
    expect(requests.map((r) => r.path), [Api.ugcUrl, Api.pgcUrl]);
    for (final request in requests) {
      expect(request.extra['account'], same(original));
      expect(request.queryParameters['cur_language'], 'ja');
      expect(request.queryParameters['voice_balance'], 1);
    }
  });
  test('已取消的媒体查询不签名或分发，签名准备异常以结果返回', () async {
    await GStorage.localCache.put(LocalCacheKey.timeStamp, 'bad cache');
    final token = CancelToken()..cancel();
    final cancelled = await VideoHttp.videoUrl(
      cid: 1,
      qn: 80,
      tryLook: false,
      videoType: VideoType.ugc,
      cancelToken: token,
    ) as Error;
    expect(cancelled.cause, same(token.cancelError));
    final malformed = await play() as Error;
    expect(malformed.cause, isA<TypeError>());
    expect(requests, isEmpty);
  });
  test('字幕使用独立正文协议，支持完整及相对地址、空字幕和三种格式', () async {
    body = {
      'body': [
        {'from': 0, 'to': 1, 'content': '字幕'},
      ],
    };
    expect(
      (await VideoHttp.getSubtitles('//fixture.test/a')).data,
      contains('WEBVTT'),
    );
    expect(requests.last.uri.toString(), 'https://fixture.test/a');
    expect(requests.last.extra['account'], isA<NoAccount>());
    expect(
      (await VideoHttp.getSubtitles(
        'https://fixture.test/a',
        format: SubtitleFormat.srt,
      )).data,
      contains('00:00:00,000'),
    );
    expect(
      (await VideoHttp.getSubtitles(
        'https://fixture.test/a',
        format: SubtitleFormat.json,
      )).data,
      contains('"body"'),
    );
    body = {'body': <Object>[]};
    expect(
      (await VideoHttp.getSubtitles('https://fixture.test/a')).data,
      'WEBVTT\n\n',
    );
  });
  test('字幕失败不再等同无数据，非法地址不发送、转换异常和断连可诊断', () async {
    final invalid = await VideoHttp.getSubtitles('file:///private-file');
    expect(invalid, isA<Error>());
    expect(requests, isEmpty);
    for (final data in [
      <String, dynamic>{},
      {
        'body': [
          {'from': 0, 'to': 1, 'content': 3},
        ],
      },
    ]) {
      body = data;
      final result =
          await VideoHttp.getSubtitles('https://fixture.test/a') as Error;
      expect(result.cause, isNotNull);
      expect(result.stackTrace, isNotNull);
    }
    fail = true;
    final failed =
        await VideoHttp.getSubtitles('https://fixture.test/a') as Error;
    expect(failed.cause, same(lastError));
  });
  test('AI 总结保留内外业务状态，预览无数据与坏响应均有明确结果', () async {
    body = {
      'code': 0,
      'data': {'code': 1},
    };
    expect(
      (await VideoHttp.aiConclusion(bvid: 'BV-test', cid: 1) as Error).code,
      1,
    );
    body = {'code': -403, 'message': '拒绝访问'};
    expect(
      (await VideoHttp.aiConclusion(bvid: 'BV-test', cid: 1) as Error).code,
      -403,
    );
    expect(
      (await VideoHttp.videoshot(bvid: 'BV-test', cid: 1) as Error).code,
      -403,
    );
    body = {
      'code': 0,
      'data': {'code': 'bad'},
    };
    expect(
      (await VideoHttp.aiConclusion(bvid: 'BV-test', cid: 1) as Error).cause,
      isA<FormatException>(),
    );
    body = {
      'code': 0,
      'data': {
        'img_x_len': 1,
        'img_y_len': 1,
        'img_x_size': 10,
        'img_y_size': 10,
        'image': [],
        'index': [],
      },
    };
    expect(
      (await VideoHttp.videoshot(bvid: 'BV-test', cid: 1)).toString(),
      '暂无视频预览',
    );
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect(
      (await VideoHttp.videoshot(bvid: 'BV-test', cid: 1) as Error).cause,
      isNotNull,
    );
  });
}
