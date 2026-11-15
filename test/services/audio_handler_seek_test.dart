import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image_ce/src/cache_api/cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

class _UnusedCache extends Fake implements BaseCacheManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    await AudioService.init(
      builder: VideoPlayerServiceHandler.new,
      cacheManager: _UnusedCache(),
      config: const AudioServiceConfig(
        fastForwardInterval: Duration(seconds: 10),
        rewindInterval: Duration(seconds: 10),
      ),
    );
  });

  void publish(
    VideoPlayerServiceHandler handler,
    int seconds, {
    bool buffering = true,
  }) {
    handler.onUpdateState(
      PlayerStatus.paused,
      buffering,
      false,
      position: Duration(seconds: seconds),
      speed: 1,
    );
  }

  VideoPlayerServiceHandler create() {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    handler.onVideoDetailChange(
      Part(part: 'fixture', duration: 600),
      1,
      'owner',
    );
    publish(handler, 100);
    return handler;
  }

  test('缓冲位置未更新时连续快进和后退累计目标', () async {
    final handler = create();
    final targets = <int>[];
    handler.onSeek = (position) async => targets.add(position.inSeconds);
    await handler.fastForward();
    await handler.fastForward();
    await handler.fastForward();
    await handler.rewind();
    expect(targets, [110, 120, 130, 120]);
  });

  test('旧跳转失败不撤销新目标，最新失败允许从真实位置重试', () async {
    final handler = create();
    final replies = <Completer<void>>[];
    final targets = <int>[];
    handler.onSeek = (position) {
      targets.add(position.inSeconds);
      final reply = Completer<void>();
      replies.add(reply);
      return reply.future;
    };
    final first = handler.fastForward();
    final firstFailure = expectLater(first, throwsStateError);
    final second = handler.fastForward();
    replies[0].completeError(StateError('old failure'));
    await firstFailure;
    final third = handler.fastForward();
    replies[1].complete();
    replies[2].completeError(StateError('latest failure'));
    await expectLater(third, throwsStateError);
    await second;
    final retry = handler.fastForward();
    replies[3].complete();
    await retry;
    expect(targets, [110, 120, 130, 110]);
  });

  test('位置确认后使用最新播放位置，绝对跳转替换相对目标', () async {
    final handler = create();
    final targets = <int>[];
    handler.onSeek = (position) async => targets.add(position.inSeconds);
    await handler.fastForward();
    publish(handler, 110, buffering: false);
    publish(handler, 150, buffering: false);
    await handler.fastForward();
    await handler.seek(const Duration(seconds: 300));
    await handler.rewind();
    expect(targets, [110, 160, 300, 290]);
  });

  test('切换媒体、回调和清空通知使旧目标失效', () async {
    final handler = create();
    final targets = <int>[];
    Future<void> record(Duration position) async =>
        targets.add(position.inSeconds);
    handler.onSeek = record;
    await handler.fastForward();
    handler.onVideoDetailChange(Part(part: 'next', duration: 600), 2, 'owner');
    publish(handler, 30);
    await handler.fastForward();
    handler.onSeek = (position) async => targets.add(position.inSeconds);
    publish(handler, 60);
    await handler.fastForward();
    handler.clear();
    handler.onVideoDetailChange(Part(part: 'new', duration: 600), 3, 'owner');
    publish(handler, 10);
    await handler.fastForward();
    expect(targets, [110, 40, 70, 20]);
  });

  test('相对目标保持在媒体时长内，直播不跳转', () async {
    final handler = create();
    final targets = <int>[];
    handler.onSeek = (position) async => targets.add(position.inSeconds);
    publish(handler, 595);
    await handler.fastForward();
    await handler.fastForward();
    await handler.seek(Duration.zero);
    await handler.rewind();
    handler.mediaItem.add(
      const MediaItem(id: 'live', title: 'live', isLive: true),
    );
    await handler.fastForward();
    expect(targets, [600, 600, 0, 0]);
  });
}
