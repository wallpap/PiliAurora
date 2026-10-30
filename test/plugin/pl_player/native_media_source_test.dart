import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

void main() {
  NetworkSource net({
    String video = 'https://example.com/video.m4s',
    String? audio = 'https://example.com/audio.m4s',
  }) => NetworkSource(videoSource: video, audioSource: audio);

  test('候选数量不同时快照能够遍历所有音视频组合', () {
    final source = NetworkSource(
      videoSource: 'video-bad',
      audioSource: 'audio-bad-1',
      videoCandidates: const ['video-good'],
      audioCandidates: const ['audio-bad-2', 'audio-good'],
    );
    final attempted = <(String, String?)>[];
    var snapshot = PlaybackSourceSnapshot.fromDataSource(source);
    do {
      attempted.add((snapshot.currentVideoSource, snapshot.currentAudioSource));
      final next = snapshot.advanceCandidate();
      if (next == null) break;
      snapshot = next;
    } while (true);

    expect(attempted, contains(('video-good', 'audio-good')));
    expect(attempted, contains(('video-bad', 'audio-good')));
    expect(attempted.toSet().length, 6);
    expect(attempted.length, 6);
  });

  test('按故障轨道切换候选，保留另一轨道，耗尽后不轮换健康轨道', () {
    final source = PlaybackSourceSnapshot.fromDataSource(
      NetworkSource(
        videoSource: 'video-primary',
        audioSource: 'audio-primary',
        videoCandidates: const ['video-backup'],
        audioCandidates: const ['audio-backup'],
      ),
    );
    for (final track in PlaybackRecoveryTrack.values) {
      final next = source.advanceCandidate(failedTrack: track)!;
      expect(
        (next.currentVideoSource, next.currentAudioSource),
        track == PlaybackRecoveryTrack.video
            ? ('video-backup', 'audio-primary')
            : ('video-primary', 'audio-backup'),
      );
      expect(next.advanceCandidate(failedTrack: track), isNull);
    }
  });

  test('合并音视频源的音频故障切换主地址', () {
    final source = PlaybackSourceSnapshot.fromDataSource(
      NetworkSource(
        videoSource: 'combined-primary',
        audioSource: null,
        videoCandidates: const ['combined-backup'],
      ),
    );
    final next = source.advanceCandidate(
      failedTrack: PlaybackRecoveryTrack.audio,
    )!;
    expect(next.currentVideoSource, 'combined-backup');
    expect(next.currentAudioSource, isNull);
  });

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

    test('播放来源快照固定候选及音轨，后续业务切换不影响已生成计划', () {
      const primaryVideo = 'https://cdn-a.example/video.m4s';
      const backupVideo = 'https://cdn-b.example/video.m4s';
      const primaryAudio = 'https://cdn-a.example/audio.m4s';
      const backupAudio = 'https://cdn-b.example/audio.m4s';
      final source = NetworkSource(
        videoSource: primaryVideo,
        audioSource: primaryAudio,
        videoCandidates: const [primaryVideo, backupVideo],
        audioCandidates: const [primaryAudio, backupAudio],
      );
      final snapshot = PlaybackSourceSnapshot.fromDataSource(source);
      final next = snapshot.advanceCandidate()!;
      expect(next.currentAudioSource, backupAudio);
      expect(snapshot.currentVideoSource, primaryVideo);

      final media = nativeMediaSourceFromSnapshot(source: snapshot);
      expect(media.uri, primaryVideo);
      expect(media.extras!['audio-files-append'], contains(primaryAudio));
    });

    test('快照源重建媒体时清除旧的外部音轨选项', () {
      final snapshot = PlaybackSourceSnapshot.fromDataSource(
        net(audio: null),
      );
      final media = nativeMediaSourceFromSnapshot(
        source: snapshot,
        extras: const {'cache': 'yes', 'audio-files-append': 'stale-audio'},
      );

      expect(media.uri, 'https://example.com/video.m4s');
      expect(media.extras, {'cache': 'yes'});
    });
  });
}
