import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

void main() {
  test('归属模型：新页面未加载时旧媒体 EOF 不产生新页面完成动作', () async {
    final runtime = _ModelRuntime();
    final session = PlaybackSession(runtime: runtime);
    final oldOwner = session.attach();
    addTearDown(session.shutdown);
    await oldOwner.load(_plan);
    final oldLoad = session.loadId;
    final nextOwner = session.attach();

    runtime.emit(
      PlaybackRuntimeEnded(
        runtimeId: runtime.runtimeId,
        loadId: oldLoad,
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 10),
      ),
    );

    expect(nextOwner.isActive, isTrue);
    expect(session.currentSnapshot.pendingAction, isNull);
    expect(session.currentSnapshot.phase, isNot(PlaybackPhase.ended));
  });

  test('意图模型：旧 writer 抛错不能结算新意图，最新暂停仍须执行', () async {
    final runtime = _ModelRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    addTearDown(session.shutdown);
    await owner.load(_plan);
    final started = Completer<void>();
    final release = Completer<void>();
    runtime.onPlaying = (playing) async {
      if (playing) {
        started.complete();
        await release.future;
        throw StateError('旧播放写入失败');
      }
      return const PlaybackRuntimeCommandResult();
    };

    final old = owner.setPlaying(true);
    await started.future;
    final latest = owner.setPlaying(false);
    expect((await old).outcome, CommandOutcome.superseded);
    release.complete();

    expect((await latest).outcome, CommandOutcome.applied);
    expect(runtime.playCalls, [false, true, false]);
    expect(session.currentSnapshot.intent.playing, isFalse);
  });
}

final _plan = PlaybackPlan(
  contentKey: 'model-video',
  source: PlaybackSourceSnapshot.fromDataSource(
    NetworkSource(
      videoSource: 'https://example.test/model.mp4',
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

class _ModelRuntime implements PlaybackRuntimePort {
  final _events = StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final _released = Completer<void>();
  final playCalls = <bool>[];
  Future<PlaybackRuntimeCommandResult> Function(bool)? onPlaying;

  @override
  int get runtimeId => 317;

  @override
  Duration? get position => Duration.zero;

  @override
  bool get shaderChangeRequiresRendererReset => false;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  void emit(PlaybackRuntimeEvent event) => _events.add(event);

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async => PlaybackRuntimeLoadResult(
    loaded: true,
    output: PlaybackOutputPreparation(
      strategy: PlaybackOutputStrategy.prepared,
      evidence: 'model-runtime',
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
    return await onPlaying?.call(playing) ??
        const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    if (!_released.isCompleted) {
      _released.complete();
      unawaited(_events.close());
    }
    return const PlaybackShutdownResult.released();
  }

  // 未被模型事件使用的端口保持显式失败，避免静默模拟原生成功。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
