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

  test('媒体上下曲只调度当前媒体，释放旧页面不清除新归属', () async {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    final calls = <String>[];
    MediaNavigation navigation(String owner) => MediaNavigation(
      isCurrent: () => true,
      next: () {
        calls.add('$owner.next');
        return true;
      },
      previous: () {
        calls.add('$owner.previous');
        return true;
      },
    );
    handler.onVideoDetailChange(
      Part(part: 'old'),
      1,
      '1',
      navigation: navigation('old'),
    );
    handler.onVideoDetailChange(
      Part(part: 'new'),
      2,
      '11',
      navigation: navigation('new'),
    );
    handler.onVideoDetailDispose('1');
    await handler.skipToNext();
    await handler.skipToPrevious();
    expect(calls, ['new.next', 'new.previous']);
    expect(handler.mediaItem.value?.title, 'new');
    expect(
      handler.playbackState.value.systemActions,
      containsAll([MediaAction.skipToNext, MediaAction.skipToPrevious]),
    );
    handler.onVideoDetailDispose('11');
    await handler.skipToNext();
    expect(calls, hasLength(2));
    expect(
      handler.playbackState.value.systemActions,
      isNot(contains(MediaAction.skipToNext)),
    );
  });

  test('媒体导航等待业务回执，禁用或失效后停止调度，错误交付调用方', () async {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    final reply = Completer<bool>();
    var current = true;
    var calls = 0;
    handler.onVideoDetailChange(
      Part(part: 'audio'),
      1,
      'audio',
      navigation: MediaNavigation(
        isCurrent: () => current,
        next: () {
          calls++;
          return reply.future;
        },
        previous: () => throw StateError('fixture failure'),
      ),
    );
    var completed = false;
    final operation = handler.skipToNext().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    reply.complete(true);
    await operation;
    await expectLater(handler.skipToPrevious(), throwsStateError);
    handler.enableBackgroundPlay = false;
    await handler.skipToNext();
    handler.enableBackgroundPlay = true;
    current = false;
    await handler.skipToNext();
    expect(calls, 1);
  });

  test('当前媒体退出后恢复上一媒体的导航，未注册的媒体不借用旧操作', () async {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    var calls = 0;
    handler.onVideoDetailChange(
      Part(part: 'video'),
      1,
      'video',
      navigation: MediaNavigation(
        isCurrent: () => true,
        next: () {
          calls++;
          return true;
        },
      ),
    );
    handler.onVideoDetailChange(Part(part: 'other'), 2, 'other');
    await handler.skipToNext();
    expect(calls, 0);
    handler.onVideoDetailDispose('other');
    await handler.skipToNext();
    expect(calls, 1);
  });

  test('音频回调未就绪时不回退触发底层视频', () async {
    final handler = VideoPlayerServiceHandler();
    var videoPlays = 0;
    var audioPlays = 0;
    final owner = Object();
    PlPlayerController.setPlayCallBack(() async => videoPlays++, owner: owner);
    addTearDown(() {
      PlPlayerController.setPlayCallBack(null, owner: owner);
      handler.clear();
    });
    handler.onPlay = () {
      audioPlays++;
      return null;
    };

    await handler.play();
    expect(audioPlays, 1);
    expect(videoPlays, 0);
    handler.onPlay = null;
    await handler.play();
    expect(videoPlays, 1);
  });

  test('同步与异步控制错误均通过返回的 Future 交付', () async {
    final handler = VideoPlayerServiceHandler();
    addTearDown(handler.clear);
    final cause = StateError('synthetic command failure');
    final stack = StackTrace.fromString('#0 audio.command');
    handler
      ..onPlay = () {
        Error.throwWithStackTrace(cause, stack);
      }
      ..onPause = () {
        return Future<void>.error(cause, stack);
      }
      ..onSeek = (_) {
        Error.throwWithStackTrace(cause, stack);
      };

    for (final command in [
      handler.play,
      handler.pause,
      () => handler.seek(Duration.zero),
    ]) {
      final operation = command();
      try {
        await operation;
        fail('command should fail');
      } catch (error, trace) {
        expect(error, same(cause));
        expect(trace.toString(), contains('#0 audio.command'));
      }
    }
  });

  test('停止回执不清除等待期间换入或替换的媒体', () async {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    final paused = Completer<void>();
    handler
      ..onVideoDetailChange(Part(part: 'old'), 1, 'current')
      ..onPause = () => paused.future;
    final stopping = handler.stop();
    handler.onVideoDetailChange(Part(part: 'new'), 2, 'current');
    paused.complete();
    await stopping;

    expect(handler.mediaItem.value?.title, 'new');
    handler.onPause = () async {};
    await handler.stop();
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
  });

  test('停止失败保留当前媒体以便重试', () async {
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    addTearDown(handler.clear);
    final cause = StateError('synthetic pause failure');
    handler
      ..onVideoDetailChange(Part(part: 'current'), 1, 'current')
      ..onPause = () async => throw cause;

    await expectLater(handler.stop(), throwsA(same(cause)));
    expect(handler.mediaItem.value?.title, 'current');
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
