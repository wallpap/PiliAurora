import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/webp_capture_operation.dart';

Future<void> settle(WidgetTester tester, Future<void> future) async {
  var completed = false;
  future.whenComplete(() => completed = true);
  for (var attempt = 0; !completed && attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(completed, isTrue, reason: '操作应在UI与会话回执排空后结束');
  await future;
}

void main() {
  Future<_Fixture> mount(WidgetTester tester, {bool playing = true}) async {
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/video',
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        getPages: [
          GetPage(name: '/video', page: () => const Scaffold()),
          GetPage(
            name: '/other',
            page: () => const Scaffold(body: Text('其他页面')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final fixture = _Fixture();
    await settle(
      tester,
      fixture.owner
          .load(
            _plan('original'),
            start: playing
                ? PlaybackStartPolicy.play
                : PlaybackStartPolicy.pause,
          )
          .then<void>((_) {}),
    );
    return fixture;
  }

  Future<void> finish(WidgetTester tester, _Fixture fixture) async {
    final toasts = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester, toasts);
    await settle(tester, fixture.session.shutdown().then<void>((_) {}));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Get.reset();
  }

  Future<({Future<void> done})> start(
    WidgetTester tester,
    WebpCaptureOperation operation,
    Future<void> Function() capture,
  ) async {
    return (done: operation.run(capture));
  }

  for (final playing in [false, true]) {
    test('取消配置只释放截图抑制，保留原${playing ? '播放' : '暂停'}意图', () async {
      final fixture = _Fixture();
      addTearDown(fixture.session.shutdown);
      await fixture.owner.load(
        _plan('original'),
        start: playing ? PlaybackStartPolicy.play : PlaybackStartPolicy.pause,
      );
      final operation = fixture.operation();
      final configuration = Completer<void>();
      final capture = operation.run(() => configuration.future);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.session.currentSnapshot.inhibitors, hasLength(1));
      expect(fixture.session.currentSnapshot.intent.playing, playing);
      expect(fixture.runtime.playCalls.last, isFalse);

      configuration.complete();
      await capture;
      expect(fixture.session.currentSnapshot.inhibitors, isEmpty);
      expect(fixture.session.currentSnapshot.intent.playing, playing);
      expect(fixture.runtime.playCalls.last, playing);
    });
  }

  test('配置期间用户主动暂停，截图结束不得补发播放', () async {
    final fixture = _Fixture();
    addTearDown(fixture.session.shutdown);
    await fixture.owner.load(
      _plan('original'),
      start: PlaybackStartPolicy.play,
    );
    final operation = fixture.operation();
    final configuration = Completer<void>();
    final capture = operation.run(() => configuration.future);
    await Future<void>.delayed(Duration.zero);
    final beforePause = fixture.runtime.playCalls.length;
    await fixture.owner.setPlaying(false);
    configuration.complete();
    await capture;
    expect(fixture.session.currentSnapshot.intent.playing, isFalse);
    expect(fixture.runtime.playCalls.skip(beforePause), everyElement(isFalse));
  });

  testWidgets('换源取消旧转换，迟到成功不保存且不改变新源暂停意图', (tester) async {
    final fixture = await mount(tester);
    final operation = fixture.operation();
    final conversion = _Conversion();
    var saved = false;
    final capture = await start(tester, operation, () async {
      if (await operation.convert(conversion)) saved = true;
    });
    await tester.pumpAndSettle();
    await settle(
      tester,
      fixture.owner
          .load(_plan('new'), start: PlaybackStartPolicy.pause)
          .then<void>((_) {}),
    );
    await tester.pumpAndSettle();
    await settle(tester, operation.cancel());
    expect(conversion.disposals, 1);
    expect(fixture.session.currentSnapshot.inhibitors, isEmpty);
    conversion.result.complete(true);
    await tester.pumpAndSettle();
    await settle(tester, capture.done);
    expect(saved, isFalse);
    expect(fixture.session.currentSnapshot.intent.playing, isFalse);
    expect(fixture.runtime.playCalls.last, isFalse);
    await finish(tester, fixture);
  });

  testWidgets('离页只撤销自己的配置弹窗，不关闭新页面', (tester) async {
    final fixture = await mount(tester);
    final operation = fixture.operation();
    final navigator = Get.key.currentState!;
    final dialog = WebpCaptureDialogRoute(
      operation: operation,
      context: navigator.context,
      builder: (_) => const AlertDialog(title: Text('截图设置')),
    );
    operation.onCancel = () {
      if (dialog.isActive) navigator.removeRoute(dialog);
    };
    final capture = await start(
      tester,
      operation,
      () => navigator.push(dialog),
    );
    await tester.pumpAndSettle();
    expect(find.text('截图设置'), findsOneWidget);
    Get.toNamed('/other');
    await tester.pumpAndSettle();
    await settle(tester, capture.done);
    expect(find.text('其他页面'), findsOneWidget);
    expect(find.text('截图设置'), findsNothing);
    expect(fixture.session.currentSnapshot.inhibitors, isEmpty);
    await finish(tester, fixture);
  });

  testWidgets('转换异常安全消费、可以重试且不关闭其他进度提示', (tester) async {
    final fixture = await mount(tester);
    SmartDialog.show<void>(
      tag: 'other-operation',
      builder: (_) => const Text('其他操作'),
      debounce: false,
      clickMaskDismiss: false,
    );
    final failed = fixture.operation();
    final conversion = _Conversion();
    final first = await start(tester, failed, () async {
      await failed.convert(conversion);
    });
    await tester.pumpAndSettle();
    conversion.result.completeError(PlatformException(code: 'secret-url'));
    await tester.pumpAndSettle();
    await settle(tester, first.done);
    expect(find.text('动态截图失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret-url'), findsNothing);
    expect(find.text('其他操作'), findsOneWidget);
    expect(conversion.disposals, 1);

    final retry = fixture.operation();
    final next = _Conversion();
    var saved = false;
    final second = await start(tester, retry, () async {
      saved = await retry.convert(next);
    });
    await tester.pumpAndSettle();
    next.result.complete(true);
    await tester.pumpAndSettle();
    await settle(tester, second.done);
    expect(saved, isTrue);
    expect(find.text('其他操作'), findsOneWidget);
    await settle(tester, SmartDialog.dismiss(tag: 'other-operation'));
    await finish(tester, fixture);
  });

  testWidgets('取消持有转换器释放Future，迟到转换不会保存', (tester) async {
    final fixture = await mount(tester);
    final operation = fixture.operation();
    final conversion = _Conversion()..release = Completer<void>();
    var saved = false;
    var finished = false;
    final capture = await start(tester, operation, () async {
      saved = await operation.convert(conversion);
    });
    final future = capture.done.whenComplete(() => finished = true);
    await tester.pumpAndSettle();
    final cancellation = operation.cancel();
    conversion.result.complete(true);
    await settle(tester, conversion.disposalStarted.future);
    expect(conversion.disposals, 1);
    expect(finished, isFalse);
    conversion.release!.complete();
    await tester.pumpAndSettle();
    await settle(tester, cancellation);
    await settle(tester, future);
    expect(saved, isFalse);
    expect(fixture.session.currentSnapshot.intent.playing, isTrue);
    await finish(tester, fixture);
  });

  test('临时路径独立，保存消费完成前取消不删除文件', () async {
    final fixture = _Fixture();
    addTearDown(fixture.session.shutdown);
    await fixture.owner.load(_plan('original'));
    final root = await Directory.systemTemp.createTemp('webp-operation-test-');
    try {
      final operation = fixture.operation();
      final other = fixture.operation();
      final saving = Completer<void>();
      final ready = Completer<void>();
      final otherReady = Completer<void>();
      late String firstPath;
      late String otherPath;
      late Future<void> first;
      late Future<void> second;
      first = operation.run(() async {
        firstPath = (await operation.createFile(root.path, 'same.webp'))!;
        await File(firstPath).writeAsBytes([1]);
        ready.complete();
        await saving.future;
      });
      second = other.run(() async {
        otherPath = (await other.createFile(root.path, 'same.webp'))!;
        otherReady.complete();
        await saving.future;
      });
      await ready.future;
      await otherReady.future;
      await operation.cancel();
      expect(File(firstPath).existsSync(), isTrue);
      expect(firstPath, isNot(otherPath));
      saving.complete();
      await Future.wait([first, second]);
      expect(root.listSync(), isEmpty);
    } finally {
      await root.delete(recursive: true);
    }
  });
}

class _Fixture {
  _Fixture() {
    session = PlaybackSession(runtime: runtime);
    owner = session.attach();
  }

  final runtime = _Runtime();
  late final PlaybackSession session;
  late final PlaybackOwner owner;

  WebpCaptureOperation operation() {
    final snapshot = session.currentSnapshot;
    return WebpCaptureOperation(
      owner: owner,
      ownsSource: () =>
          session.currentSnapshot.requestId == snapshot.requestId &&
          session.currentSnapshot.loadId == snapshot.loadId,
    );
  }
}

class _Conversion implements WebpConversion {
  final result = Completer<bool>();
  final disposalStarted = Completer<void>();
  Completer<void>? release;
  int disposals = 0;

  @override
  Future<bool> convert() => result.future;

  @override
  Future<void> dispose() async {
    disposals++;
    if (!disposalStarted.isCompleted) disposalStarted.complete();
    await release?.future;
  }
}

PlaybackPlan _plan(String key) => PlaybackPlan(
  contentKey: key,
  source: PlaybackSourceSnapshot.fromDataSource(
    NetworkSource(
      videoSource: 'https://example.test/$key.mp4',
      audioSource: null,
    ),
  ),
  timeline: const PlaybackTimeline(
    kind: PlaybackTimelineKind.onDemand,
    seekPolicy: PlaybackSeekPolicy.allowed,
    duration: Duration(seconds: 10),
  ),
  configuration: PlaybackConfiguration(),
);

class _Runtime implements PlaybackRuntimePort {
  final _events = StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final _released = Completer<void>();
  final playCalls = <bool>[];

  @override
  int get runtimeId => 417;

  @override
  Duration? get position => Duration.zero;

  @override
  bool get shaderChangeRequiresRendererReset => false;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async => PlaybackRuntimeLoadResult(
    loaded: true,
    output: PlaybackOutputPreparation(
      strategy: PlaybackOutputStrategy.prepared,
      evidence: 'webp-operation-test',
      outputEpoch: context.loadId,
      hasVideo: true,
    ),
  );

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) async {
    playCalls.add(playing);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    if (!_released.isCompleted) {
      _released.complete();
      unawaited(_events.close());
    }
    return const PlaybackShutdownResult.released();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
