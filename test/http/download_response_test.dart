import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/download.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../services/download/download_fixtures.dart';
import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(Response(requestOptions: options, data: body));
          },
        ),
      );
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('下载失败抛出携带业务码的异常', () async {
    body = {'code': -404, 'message': 'not found'};
    await expectLater(
      DownloadHttp.getVideoUrl(entry: downloadEntry()),
      throwsA(isA<Error>().having((error) => error.code, 'code', -404)),
    );
  });

  test('有视频流但缺少可选格式与音频显示字段仍可准备下载', () async {
    final entry = downloadEntry()..mediaType = 1;
    body = {
      'code': 0,
      'data': {
        'dash': {
          'duration': 60,
          'video': [_video(80)],
          'audio': [
            {'id': 30280, 'base_url': 'https://example.test/audio'},
          ],
        },
      },
    };
    final result = await DownloadHttp.getVideoUrl(entry: entry) as Type2;
    expect(result.video.single.baseUrl, 'https://example.test/video80');
    expect(result.audio!.single.baseUrl, 'https://example.test/audio');
    expect(result.audio!.single.frameRate, isEmpty);
    expect(entry.mediaType, 2);
    expect(entry.hasDashAudio, isTrue);
  });

  test('画质只从实际媒体流中选择，重试清除旧的音频标记', () async {
    final entry = downloadEntry()
      ..preferedVideoQuality = 64
      ..hasDashAudio = true;
    body = {
      'code': 0,
      'data': {
        'accept_quality': [120, 80, 64, 32],
        'dash': {
          'duration': 60,
          'video': [_video(80), _video(32)],
        },
      },
    };
    final result = await DownloadHttp.getVideoUrl(entry: entry) as Type2;
    expect(result.video.single.id, 32);
    expect(entry.videoQuality, 32);
    expect(entry.hasDashAudio, isFalse);
  });

  test('成功响应未提供媒体时抛出明确的格式异常', () async {
    for (final data in <Map<String, dynamic>>[
      {},
      {
        'dash': {'video': []},
      },
      {
        'dash': {
          'video': [
            {'id': 80},
          ],
        },
      },
    ]) {
      body = {'code': 0, 'data': data};
      await expectLater(
        DownloadHttp.getVideoUrl(entry: downloadEntry()),
        throwsA(isA<FormatException>()),
      );
    }
  });
}

Map<String, Object> _video(int quality) => {
  'id': quality,
  'base_url': 'https://example.test/video$quality',
  'codecs': 'avc1.640028',
  'codecid': 7,
  'width': 1920,
  'height': 1080,
};
