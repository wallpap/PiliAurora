import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/audio/controller.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/services/shutdown_timer_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

class _Settings extends MemoryBox<dynamic> {
  Object? saveError;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (saveError case final error?) throw error;
    await super.put(key, value);
  }
}

class _Player implements Player {
  @override
  final state = PlayerState(position: const Duration(seconds: 7));
  Object? commandError;
  Object? disposeError;
  Completer<void>? rateResult;
  Completer<void>? volumeResult;
  Completer<void>? seekResult;
  var disposeCount = 0;

  Future<void> _command() async {
    if (commandError case final error?) throw error;
  }

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {
    await rateResult?.future;
    await _command();
    state.rate = rate;
  }

  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) async {
    await volumeResult?.future;
    await _command();
    state.volume = volume;
  }

  @override
  Future<void> seek(
    Duration position, {
    bool synchronized = true,
    int? observationId,
  }) async {
    await seekResult?.future;
    await _command();
    state.position = position;
  }

  @override
  Future<void> play({bool synchronized = true}) => _command();
  @override
  Future<void> pause({bool synchronized = true}) => _command();
  @override
  Future<void> playOrPause({bool notify = true, bool synchronized = true}) =>
      _command();
  @override
  Future<void> dispose({bool synchronized = true}) {
    disposeCount++;
    if (disposeError case final error?) throw error;
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _check(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    await tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
    );
    try {
      await body(tester);
    } finally {
      SmartDialog.dismiss(status: SmartStatus.allToast);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Settings settings;
  late _Player player;
  late AudioController controller;
  var closed = false;

  AudioController createController() {
    final result = AudioController();
    result.animController = AnimationController(
      vsync: result,
      duration: const Duration(milliseconds: 200),
    );
    return result;
  }

  setUpAll(() {
    settings = _Settings();
    GStorage.setting = settings;
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
  });
  setUp(() {
    settings.data.clear();
    settings.saveError = null;
    closed = false;
    player = _Player();
    controller = createController()..player = player;
  });
  tearDown(() {
    if (!closed) controller.onClose();
    videoPlayerServiceHandler = null;
    shutdownTimerService
      ..onPause = null
      ..isPlaying = null
      ..reset();
  });

  _check('speed waits for native success and failure permits retry', (
    tester,
  ) async {
    player.rateResult = Completer<void>();
    final first = controller.setSpeed(1.5);
    expect(controller.speed, 1);
    player.commandError = StateError('https://private?token=secret');
    player.rateResult!.complete();
    expect(await first, isFalse);
    expect(controller.speed, 1);
    await tester.pump();
    expect(find.text('播放速度调整失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    player.commandError = null;
    expect(await controller.setSpeed(1.5), isTrue);
    expect(controller.speed, 1.5);
  });

  _check('volume confirms and persists only successful native changes', (
    tester,
  ) async {
    controller.desktopVolume.value = 0.8;
    player.commandError = StateError('synthetic volume failure');
    controller.previewVolume(0.3);
    await tester.pump();
    expect(controller.desktopVolume.value, 0.8);
    expect(controller.volumeDraft.value, 0.8);
    await controller.setPlayerVolumePercent(30);
    expect(settings.data, isEmpty);
    player
      ..commandError = null
      ..volumeResult = Completer<void>();
    final operation = controller.setPlayerVolumePercent(40);
    expect(controller.desktopVolume.value, 0.8);
    expect(settings.data, isEmpty);
    player.volumeResult!.complete();
    await operation;
    expect(controller.desktopVolume.value, 0.4);
    expect(settings.data[SettingBoxKey.playerVolume], 40);
  });

  _check('settings save failure preserves accepted volume and is consumed', (
    tester,
  ) async {
    settings.saveError = StateError('https://private?token=secret');
    await controller.setPlayerVolumePercent(40);
    expect(controller.desktopVolume.value, 0.4);
    expect(player.state.volume, 40);
    await tester.pump();
    expect(find.text('音量已调整，设置保存失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
  });

  _check('control completion after account replacement is not confirmed', (
    tester,
  ) async {
    final originalAccount = Accounts.main;
    player.rateResult = Completer<void>();
    final operation = controller.setSpeed(1.5);
    Accounts.accountMode[AccountType.main.index] = const NoAccount();
    try {
      player.rateResult!.complete();
      expect(await operation, isFalse);
      expect(controller.speed, 1);
    } finally {
      Accounts.accountMode[AccountType.main.index] = originalAccount;
    }
  });

  _check('system controls propagate original errors while UI consumes them', (
    tester,
  ) async {
    final cause = StateError('https://private?token=secret');
    player.commandError = cause;
    await expectLater(controller.onPlay(), throwsA(same(cause)));
    await expectLater(controller.onPause(), throwsA(same(cause)));
    await controller.playOrPause();
    await tester.pump();
    expect(find.text('播放操作失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    controller.player = null;
    await expectLater(controller.onPause(), throwsStateError);
  });

  _check('seek failure restores actual position and successful seek waits', (
    tester,
  ) async {
    controller.position.value = 40;
    player.commandError = StateError('synthetic seek failure');
    await controller.seekFromUi(const Duration(seconds: 40));
    expect(controller.position.value, 7);
    player
      ..commandError = null
      ..seekResult = Completer<void>();
    final operation = controller.onSeek(const Duration(seconds: 20));
    expect(controller.position.value, 7);
    player.seekResult!.complete();
    await operation;
    expect(controller.position.value, 20);
  });

  _check('old close preserves newer callbacks and consumes dispose failure', (
    tester,
  ) async {
    final newer = createController();
    final handler = VideoPlayerServiceHandler();
    videoPlayerServiceHandler = handler;
    handler
      ..onPlay = newer.onPlay
      ..onPause = newer.onPause
      ..onSeek = newer.onSeek;
    shutdownTimerService
      ..onPause = newer.onPause
      ..isPlaying = newer.isPlaying
      ..reset(5);
    player.disposeError = StateError('https://private?token=secret');
    try {
      controller.onClose();
      closed = true;
      await tester.pump();
      expect(player.disposeCount, 1);
      expect(handler.onPlay, newer.onPlay);
      expect(handler.onPause, newer.onPause);
      expect(handler.onSeek, newer.onSeek);
      expect(shutdownTimerService.onPause, newer.onPause);
      expect(shutdownTimerService.isPlaying, newer.isPlaying);
      expect(shutdownTimerService.durationInMinutes, 5);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('secret'), findsNothing);
    } finally {
      newer.onClose();
      handler.clear();
    }
  });
}
