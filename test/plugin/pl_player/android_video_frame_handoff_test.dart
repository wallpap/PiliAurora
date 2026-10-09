import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_video_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Player player;
  late List<String> events;
  late Completer<bool> frame;
  late Completer<void> entered;
  String? waitingRequest;

  setUp(() {
    player = _Player();
    events = [];
    frame = Completer<bool>();
    entered = Completer<void>();
    waitingRequest = null;
    player.onSize = () => events.add('mpv');
    messenger.setMockMethodCallHandler(channel, (call) async {
      events.add(call.method);
      if (call.method == 'VideoOutputManager.CanWaitForSurfaceFrame') {
        return true;
      }
      if (call.method == 'VideoOutputManager.WaitForSurfaceFrame') {
        waitingRequest = (call.arguments as Map)['request'] as String;
        entered.complete();
        return frame.future;
      }
      if (call.method == 'VideoOutputManager.CancelSurfaceFrameWait') {
        expectSync((call.arguments as Map)['request'], waitingRequest);
        frame.complete(false);
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'handoff completion waits for acquired frame, not buffer and mpv return',
    () async {
      var completed = false;
      final resize =
          setAndroidVideoOutputSize(
            player: player,
            size: (width: 1156, height: 650),
            waitForFrame: true,
          ).then((accepted) {
            completed = true;
            return accepted;
          });
      await entered.future;
      expect(completed, isFalse);
      expect(events, [
        'VideoOutputManager.CanWaitForSurfaceFrame',
        'VideoOutputManager.SetSurfaceTextureSize',
        'mpv',
        'VideoOutputManager.WaitForSurfaceFrame',
      ]);
      frame.complete(true);
      expect(await resize, isTrue);
    },
  );

  test(
    'source invalidation cancels receipt and unblocks source-size rebuild',
    () async {
      var current = true;
      final resize = setAndroidVideoOutputSize(
        player: player,
        size: (width: 1156, height: 650),
        isCurrent: () => current,
        waitForFrame: true,
      );
      await entered.future;
      current = false;
      player.current[0] = const Media('file:///next.mp4');
      final source = setAndroidSurfaceSize(
        player: player,
        width: 3840,
        height: 2160,
        wid: 8,
      );
      expect(
        events.where((e) => e == 'VideoOutputManager.SetSurfaceTextureSize'),
        hasLength(1),
      );
      await cancelAndroidSurfaceFrameWait(player);
      expect(await resize, isFalse);
      expect(await source, isTrue);
      expect(player.options, [
        ('android-surface-size', '1156x650'),
        ('android-surface-size', '3840x2160'),
        ('wid', '8'),
        ('vo', 'gpu'),
      ]);
    },
  );

  test('unsupported frame clock refuses before touching buffer', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      events.add(call.method);
      return false;
    });
    expect(
      await setAndroidVideoOutputSize(
        player: player,
        size: (width: 1156, height: 650),
        waitForFrame: true,
      ),
      isFalse,
    );
    expect(events, ['VideoOutputManager.CanWaitForSurfaceFrame']);
    expect(player.options, isEmpty);
  });

  test('stale geometry while queued never begins buffer resize', () async {
    var mayStart = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      events.add(call.method);
      mayStart = false;
      return true;
    });
    expect(
      await setAndroidVideoOutputSize(
        player: player,
        size: (width: 1156, height: 650),
        waitForFrame: true,
        canStart: () => mayStart,
      ),
      isFalse,
    );
    expect(events, ['VideoOutputManager.CanWaitForSurfaceFrame']);
    expect(player.options, isEmpty);
  });

  test(
    'failed or cancelled current receipt is not a successful handoff',
    () async {
      final resize = setAndroidVideoOutputSize(
        player: player,
        size: (width: 1156, height: 650),
        waitForFrame: true,
      );
      await entered.future;
      frame.complete(false);
      await expectLater(resize, throwsStateError);
    },
  );
}

class _Player implements NativePlayer {
  @override
  bool disposed = false;
  @override
  final List<Media> current = [const Media('file:///source.mp4')];
  @override
  int get handle => 42;
  final options = <(String, String)>[];
  void Function()? onSize;
  @override
  void setOption(String option, String value) {
    options.add((option, value));
    if (option == 'android-surface-size') onSize?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
