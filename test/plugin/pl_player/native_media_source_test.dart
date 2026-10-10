import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

void main() {
  NetworkSource net({
    String video = 'https://example.com/video.m4s',
    String? audio = 'https://example.com/audio.m4s',
  }) => NetworkSource(videoSource: video, audioSource: audio);

  test('候选数量不同时能够找到可用的音视频组合', () {
    final source = NetworkSource(
      videoSource: 'video-bad',
      audioSource: 'audio-bad-1',
      videoCandidates: const ['video-good'],
      audioCandidates: const ['audio-bad-2', 'audio-good'],
    );
    final attempted = <(String, String?)>[];
    do {
      attempted.add((source.currentVideoSource, source.currentAudioSource));
    } while (source.advanceCandidate());

    expect(attempted, contains(('video-good', 'audio-good')));
    expect(attempted, contains(('video-bad', 'audio-good')));
    expect(attempted.toSet().length, 6);
    expect(attempted.length, 6);
    expect(source.advanceCandidate(), isFalse);
  });

  group('reloadNativeMedia', () {
    test(
      'paused DASH reload preserves position and the separate audio track',
      () async {
        final media = nativeMediaSource(
          source: net(),
          extras: {'cache': 'yes'},
        );
        final player = _ReloadPlayer(media)
          ..state.position = const Duration(milliseconds: 90882);
        expect(await reloadNativeMedia(player: player, isLive: false), isTrue);
        expect(player.opened!.uri, media.uri);
        expect(player.opened!.extras, media.extras);
        expect(player.opened!.start, const Duration(milliseconds: 90882));
        expect(player.openedPlaying, isFalse);
      },
    );

    test('playing media continues playing and live does not seek', () async {
      final media = nativeMediaSource(source: net());
      final player = _ReloadPlayer(media)
        ..state.position = const Duration(seconds: 90)
        ..state.playing = true;
      await reloadNativeMedia(player: player, isLive: false);
      expect(player.openedPlaying, isTrue);
      expect(player.opened!.start, const Duration(seconds: 90));
      await reloadNativeMedia(player: player, isLive: true);
      expect(player.opened, same(media));
      expect(player.opened!.start, isNull);
    });

    test(
      'CDN fallback keeps position, playback state and DASH audio',
      () async {
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
        final media = nativeMediaSource(
          source: source,
          extras: const {'cache': 'yes'},
        );
        expect(media.uri, primaryVideo);
        while (source.currentVideoSource != backupVideo ||
            source.currentAudioSource != backupAudio) {
          expect(source.advanceCandidate(), isTrue);
        }

        final player = _ReloadPlayer(media)
          ..state.position = const Duration(seconds: 42)
          ..state.playing = true;
        expect(
          await reloadNativeMedia(
            player: player,
            isLive: false,
            source: source,
          ),
          isTrue,
        );
        expect(player.opened!.uri, backupVideo);
        expect(player.opened!.start, const Duration(seconds: 42));
        expect(player.openedPlaying, isTrue);
        expect(player.opened!.extras!['cache'], 'yes');
        expect(
          player.opened!.extras!['audio-files-append'],
          contains(backupAudio),
        );
        expect(source.advanceCandidate(), isFalse);
      },
    );

    test('听视频回退清除旧音轨并保留其余配置和暂停位置', () async {
      final source = NetworkSource(
        videoSource: 'https://cdn.example/video.m4s',
        videoCandidates: const ['https://cdn-backup.example/video.m4s'],
        audioSource: 'https://cdn-a.example/audio.m4s',
        audioCandidates: const ['https://cdn-b.example/audio.m4s'],
      );
      final media = nativeMediaSource(
        source: source,
        extras: const {'cache': 'yes', 'vid': 'no'},
      );
      final originalExtras = Map<String, String>.of(media.extras!);
      expect(source.advanceCandidate(audioOnly: true), isTrue);
      final player = _ReloadPlayer(media)
        ..state.position = const Duration(seconds: 42);

      await reloadNativeMedia(
        player: player,
        isLive: false,
        source: source,
        audioOnly: true,
      );

      expect(player.opened!.uri, 'https://cdn-b.example/audio.m4s');
      expect(player.opened!.extras, {'cache': 'yes', 'vid': 'no'});
      expect(player.opened!.start, const Duration(seconds: 42));
      expect(player.openedPlaying, isFalse);
      expect(media.extras, originalExtras);
      expect(source.currentVideoSource, 'https://cdn.example/video.m4s');
      expect(source.advanceCandidate(audioOnly: true), isFalse);
    });

    test('disposed, empty and stale players do not reload', () async {
      final player = _ReloadPlayer(nativeMediaSource(source: net()));
      expect(
        await reloadNativeMedia(
          player: player,
          isLive: false,
          isCurrent: () => false,
        ),
        isFalse,
      );
      expect(player.opened, isNull);
      player.disposed = true;
      expect(await reloadNativeMedia(player: player, isLive: false), isFalse);
      player.disposed = false;
      player.current.clear();
      expect(await reloadNativeMedia(player: player, isLive: false), isFalse);
      expect(player.opened, isNull);
    });

    test('open failures propagate to the recovery error handler', () async {
      final player = _ReloadPlayer(nativeMediaSource(source: net()))
        ..openError = StateError('load failed');
      await expectLater(
        reloadNativeMedia(player: player, isLive: false),
        throwsStateError,
      );
    });
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

class _ReloadPlayer implements NativePlayer {
  _ReloadPlayer(Media media) : current = [media];

  @override
  bool disposed = false;
  @override
  final List<Media> current;
  @override
  final PlayerState state = PlayerState();
  Media? opened;
  bool? openedPlaying;
  Object? openError;

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    if (openError case final error?) throw error;
    opened = playable as Media;
    openedPlaying = play;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
