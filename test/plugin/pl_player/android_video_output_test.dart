import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_video_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Player player;
  late List<MethodCall> calls;

  setUp(() {
    player = _Player();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('updates the buffer before notifying mpv', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(player.options, isEmpty);
      calls.add(call);
      return null;
    });
    await setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
    );
    expect(calls.single.method, 'VideoOutputManager.SetSurfaceTextureSize');
    expect(calls.single.arguments, {
      'handle': '42',
      'width': '960',
      'height': '540',
    });
    expect(player.options, [
      ('android-surface-size', '960x540'),
      ('vo', 'gpu'),
    ]);
  });

  test('disposed and unloaded players do not touch native resources', () async {
    player.disposed = true;
    await setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
    );
    expect(calls, isEmpty);
    player.disposed = false;
    player.current.clear();
    await setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
    );
    expect(calls, isEmpty);
    expect(player.options, isEmpty);
  });

  test('disposal while resizing never enters mpv again', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      entered.complete();
      await gate.future;
      return null;
    });
    final resize = setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
    );
    await entered.future;
    player.disposed = true;
    gate.complete();
    await resize;
    expect(player.options, isEmpty);
  });

  test(
    'a media switch during resizing never reconfigures the new source',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        player.current[0] = const Media('file:///next.mp4');
        return null;
      });
      await setAndroidVideoOutputSize(
        player: player,
        size: (width: 960, height: 540),
      );
      expect(player.options, isEmpty);
    },
  );

  test('stale surface generations do not enter the native channel', () async {
    final applied = await setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
      isCurrent: () => false,
    );
    expect(applied, isFalse);
    expect(calls, isEmpty);
  });

  test('surface invalidation while waiting never reconfigures mpv', () async {
    var current = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      current = false;
      return null;
    });
    final applied = await setAndroidVideoOutputSize(
      player: player,
      size: (width: 960, height: 540),
      isCurrent: () => current,
    );
    expect(applied, isFalse);
    expect(player.options, isEmpty);
  });

  test('a failed channel does not reconfigure mpv', () async {
    messenger.setMockMethodCallHandler(channel, (call) {
      return Future<Object?>.error(PlatformException(code: 'resize-failed'));
    });
    await expectLater(
      setAndroidVideoOutputSize(
        player: player,
        size: (width: 960, height: 540),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(player.options, isEmpty);
  });
}

class _Player implements NativePlayer {
  @override
  bool disposed = false;
  @override
  final List<Media> current = [const Media('file:///test.mp4')];
  @override
  int get handle => 42;
  final options = <(String, String)>[];
  @override
  void setOption(String opt, String value) => options.add((opt, value));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
