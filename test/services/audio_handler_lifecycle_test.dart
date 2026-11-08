import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart'
    show Part;
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:audio_service/audio_service.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
  });

  test('关闭服务立即清除通知，禁用期间 clear 仍清理媒体', () {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    handler
      ..onVideoDetailChange(Part(part: 'current'), 1, 'current')
      ..onUpdateState(
        PlayerStatus.playing,
        false,
        false,
        position: Duration.zero,
        speed: 1,
      )
      ..enableBackgroundPlay = false;
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(handler.playbackState.value.playing, isFalse);
    handler
      ..clear()
      ..enableBackgroundPlay = true;
    expect(handler.mediaItem.value, isNull);
  });

  test('暂停期间缓冲保留暂停按钮语义', () {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    handler
      ..onVideoDetailChange(Part(part: 'current'), 1, 'current')
      ..onUpdateState(
        PlayerStatus.paused,
        true,
        false,
        position: const Duration(seconds: 5),
        speed: 1,
      );
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.buffering,
    );
    expect(handler.playbackState.value.controls[1].action, MediaAction.play);
  });

  test('媒体尚未准备完成时发布加载状态', () {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    handler
      ..onVideoDetailChange(Part(part: 'current'), 1, 'current')
      ..onUpdateState(
        PlayerStatus.paused,
        false,
        false,
        position: Duration.zero,
        speed: 1,
        loading: true,
      );
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.loading,
    );
  });

  test('禁用时缓存当前媒体和状态，开启后立即发布并排除已退出页面', () {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = false;
    addTearDown(handler.clear);
    handler
      ..onVideoDetailChange(Part(part: 'old'), 1, 'old')
      ..onVideoDetailChange(Part(part: 'current'), 2, 'current')
      ..onVideoDetailDispose('old')
      ..onUpdateState(
        PlayerStatus.playing,
        false,
        false,
        position: const Duration(seconds: 8),
        speed: 1.5,
      );
    expect(handler.mediaItem.value, isNull);
    handler.enableBackgroundPlay = true;
    expect(handler.mediaItem.value?.id, '2current');
    expect(handler.playbackState.value.playing, isTrue);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 8),
    );
    expect(handler.playbackState.value.speed, 1.5);
    handler
      ..enableBackgroundPlay = false
      ..onVideoDetailDispose('current')
      ..enableBackgroundPlay = true;
    expect(handler.mediaItem.value, isNull);
  });

  test(
    'last media item releases its lease after older page disposal',
    () async {
      final controller = PlPlayerController.getInstance();
      final firstOwner = controller.attachPlaybackOwner();
      final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
      videoPlayerServiceHandler = handler;
      PlaybackOwner? secondOwner;
      addTearDown(() async {
        handler.clear();
        controller.closePlaybackOwner(firstOwner);
        if (secondOwner case final owner?) {
          controller.closePlaybackOwner(owner);
        }
        try {
          await controller.playbackReleased.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // 保持 teardown 有界；主断言会报告 lease 是否阻止了释放。
        }
        videoPlayerServiceHandler = null;
      });

      handler.onVideoDetailChange(Part(part: 'first'), 1, 'first');
      secondOwner = controller.attachPlaybackOwner();
      handler.onVideoDetailChange(Part(part: 'second'), 2, 'second');
      var released = false;
      unawaited(controller.playbackReleased.then((_) => released = true));

      handler.onVideoDetailDispose('first');
      expect(handler.mediaItem.value?.id, '2second');
      controller.closePlaybackOwner(firstOwner);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);

      handler.onVideoDetailDispose('second');
      expect(handler.mediaItem.value, isNull);
      controller.closePlaybackOwner(secondOwner);
      await controller.playbackReleased.timeout(const Duration(seconds: 2));

      expect(released, isTrue);
    },
  );

  test('开启服务为当前媒体取得 keepalive，关闭服务释放租约', () async {
    final controller = PlPlayerController.getInstance();
    final owner = controller.attachPlaybackOwner();
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = false;
    addTearDown(() async {
      handler.clear();
      controller.closePlaybackOwner(owner);
      await controller.playbackReleased.timeout(const Duration(seconds: 2));
    });
    handler
      ..onVideoDetailChange(Part(part: 'current'), 1, 'current')
      ..enableBackgroundPlay = true;
    var released = false;
    unawaited(controller.playbackReleased.then((_) => released = true));
    controller.closePlaybackOwner(owner);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);
    handler.enableBackgroundPlay = false;
    await controller.playbackReleased.timeout(const Duration(seconds: 2));
    expect(released, isTrue);
    expect(handler.mediaItem.value, isNull);
  });
}
