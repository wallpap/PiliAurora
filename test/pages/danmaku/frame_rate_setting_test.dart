import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';

import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/pages/danmaku/view.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/view.dart' as live;
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'frame_rate_settings',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() => GStorage.setting.close());

  for (final isLive in [false, true]) {
    testWidgets('保存帧率后当前${isLive ? '直播' : '视频'}弹幕立即更新且保留控制器', (tester) async {
      final player = _Player(isLive: isLive);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: isLive
                ? live.LiveDanmaku(
                    liveRoomController: _LiveRoom(),
                    plPlayerController: player,
                    isFullScreen: false,
                    size: const Size(800, 600),
                  )
                : PlDanmaku(
                    cid: 1,
                    playerController: player,
                    isFullScreen: false,
                    isFileSource: false,
                    size: const Size(800, 600),
                  ),
          ),
        ),
      );
      final timeline = find.byWidgetPredicate(
        (w) => w is DanmakuWindowScreen,
        skipOffstage: false,
      );
      final liveLayer = find.byWidgetPredicate(
        (w) => w is LiveDanmakuLayer,
        skipOffstage: false,
      );
      int rate() => isLive
          ? tester.widget<LiveDanmakuLayer>(liveLayer).frameRate
          : tester.widget<DanmakuWindowScreen>(timeline).frameRate;
      Object? syncState() => isLive
          ? tester.widget<LiveDanmakuLayer>(liveLayer).frameSource
          : tester.widget<DanmakuWindowScreen>(timeline).frameSource;
      final controller = player.danmakuDisplay;
      expect(rate(), 0);
      expect(syncState(), same(player.frameSource));
      await GStorage.setting.put(SettingBoxKey.videoSync, 'audio');
      await tester.pump();
      expect(syncState(), same(player.frameSource));
      for (final fps in [60, 90, 120, 30, 0]) {
        await GStorage.setting.put(SettingBoxKey.danmakuFrameRate, fps);
        await tester.pump();
        expect(rate(), Platform.isWindows || fps == 30 ? 0 : fps);
        expect(player.danmakuDisplay, same(controller));
      }
      if (isLive) {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      player.videoDisplaySyncActive.dispose();
      (player.frameSource as _FrameSource).frameState.dispose();
      await GStorage.setting.delete(SettingBoxKey.videoSync);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Player implements PlPlayerController {
  _Player({required this.isLive});
  @override
  final bool isLive;
  @override
  final PlaybackFrameSource frameSource = _FrameSource();
  @override
  final ValueNotifier<bool> videoDisplaySyncActive = ValueNotifier<bool>(true);
  @override
  final enableShowDanmaku = false.obs;
  @override
  final enableShowLiveDanmaku = false.obs;
  @override
  final danmakuOpacity = 1.0.obs;
  @override
  bool get mergeDanmaku => false;
  @override
  double get playbackSpeed => 1;
  @override
  PlayerStatus get playerStatus => PlayerStatus.paused;
  @override
  DanmakuDisplayBinding? danmakuDisplay;
  @override
  PlaybackMediaClock get mediaClock => _Clock();
  @override
  bool get showDanmaku => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LiveRoom implements LiveRoomController {
  @override
  Stream<LiveDanmakuMessage<DanmakuExtra>> get liveDanmakuMessages =>
      const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Clock implements PlaybackMediaClock {
  @override
  PlaybackMediaAnchor? get currentMediaAnchor => null;
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => const Stream.empty();
}

class _FrameSource implements PlaybackFrameSource {
  @override
  final ValueNotifier<PlaybackFrameState> frameState = ValueNotifier(
    const PlaybackFrameState(),
  );
}
