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

    expect(
      attempted,
      unorderedEquals([
        for (final video in ['video-bad', 'video-good'])
          for (final audio in ['audio-bad-1', 'audio-bad-2', 'audio-good'])
            (video, audio),
      ]),
    );
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
    test('独立音轨保留主 URL、起始位置及 extras，不修改调用方数据', () {
      final extras = <String, String>{'cache': 'yes'};
      final media = nativeMediaSource(
        source: net(),
        start: const Duration(seconds: 30),
        extras: extras,
      );
      expect(media.uri, 'https://example.com/video.m4s');
      expect(media.start, const Duration(seconds: 30));
      expect(media.extras!['cache'], 'yes');
      expect(
        media.extras!['audio-files-append'],
        contains('https://example.com/audio.m4s'),
      );
      expect(extras, {'cache': 'yes'});
    });

    test('只听音频优先独立音轨，空音轨回退视频且不追加选项', () {
      for (final audio in ['', null]) {
        for (final audioOnly in [false, true]) {
          final media = nativeMediaSource(
            source: net(audio: audio),
            audioOnly: audioOnly,
          );
          expect(media.uri, 'https://example.com/video.m4s');
          expect(media.extras, isNull);
        }
      }
      final media = nativeMediaSource(source: net(), audioOnly: true);
      expect(media.uri, 'https://example.com/audio.m4s');
      expect(media.extras, isNull);
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
