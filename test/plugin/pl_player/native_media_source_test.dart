import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

void main() {
  NetworkSource net({
    String video = 'https://example.com/video.m4s',
    String? audio = 'https://example.com/audio.m4s',
  }) => NetworkSource(videoSource: video, audioSource: audio);

  group('nativeMediaSource', () {
    test('网络源带独立音轨时主 URL 直接作为播放目标', () {
      final media = nativeMediaSource(source: net());
      expect(media.uri, 'https://example.com/video.m4s');
      expect(media.extras!.keys, ['audio-files-append']);
    });

    test('保留 start 并透传 extras', () {
      final media = nativeMediaSource(
        source: net(),
        start: const Duration(seconds: 30),
        extras: const {'cache': 'yes'},
      );
      expect(media.start, const Duration(seconds: 30));
      expect(media.extras!.keys, containsAll(['cache', 'audio-files-append']));
    });
    test('音轨为空字符串或 null 时不追加音轨', () {
      expect(nativeMediaSource(source: net(audio: '')).extras, isNull);
      expect(nativeMediaSource(source: net(audio: null)).extras, isNull);
    });
    test('audioOnly 且存在独立音轨时只加载音轨', () {
      final media = nativeMediaSource(source: net(), audioOnly: true);
      expect(media.uri, 'https://example.com/audio.m4s');
      expect(media.extras, isNull);
    });

    test('audioOnly 且无独立音轨时退回视频源', () {
      expect(
        nativeMediaSource(source: net(audio: null), audioOnly: true).uri,
        'https://example.com/video.m4s',
      );
    });
    test('离线 Windows 路径含逗号、分号与反斜杠时按 UTF-8 字节长度转义', () {
      const audio = r'C:\媒体 文件\a,b;c.m4s';
      final media = nativeMediaSource(
        source: NetworkSource(
          videoSource: r'C:\媒体 文件\v.m4s',
          audioSource: audio,
        ),
      );
      final track = media.extras!['audio-files-append']!;
      final actual = track.substring(track.indexOf('%', 1) + 1);
      expect(actual, endsWith(audio));
      expect(track, startsWith('%${utf8.encode(actual).length}%'));
      expect(media.uri, isNot(startsWith('edl://')));
    });
    test('不修改调用方传入的 extras', () {
      final extras = <String, String>{'cache': 'yes'};
      nativeMediaSource(source: net(), extras: extras);
      expect(extras, {'cache': 'yes'});
    });

    test('reload 时 copyWith 保留已追加的外部音轨', () {
      final media = nativeMediaSource(
        source: net(),
        start: const Duration(seconds: 10),
      );
      final reloaded = media.copyWith(start: const Duration(seconds: 60));
      expect(reloaded.uri, media.uri);
      expect(reloaded.start, const Duration(seconds: 60));
      expect(reloaded.extras, media.extras);
    });
  });
}
