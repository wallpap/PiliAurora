import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

void main() {
  test('到达总 deadline 时结算加载，旧原生调用排空后可再次加载', () async {
    var now = Duration.zero;
    final runtime = _AcceptanceRuntime();
    const budget = Duration(milliseconds: 40);
    final session = PlaybackSession(
      runtime: runtime,
      loadBudget: budget,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final started = Completer<void>();
    final release = Completer<void>();
    runtime.onLoad = (plan, context, index) async {
      if (index == 0) {
        started.complete();
        await release.future;
      }
      return _loaded(context, plan);
    };
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      owner.close();
      await session.shutdown();
    });

    final load = owner.load(_plan('timed-out'));
    await started.future;
    now = budget;
    final result = await load.timeout(const Duration(seconds: 2));
    expect(result.outcome, LoadOutcome.failed);
    expect(result.failure?.category, PlaybackFailureCategory.timeout);
    expect(session.currentSnapshot.phase, PlaybackPhase.failed);

    release.complete();
    await session.drained;
    expect(session.currentSnapshot.phase, PlaybackPhase.failed);
    expect((await owner.load(_plan('next'))).outcome, LoadOutcome.ready);
  });

  testWidgets('query 总 deadline 包含来源解析和等待旧原生调用排空', (tester) async {
    var now = Duration.zero;
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      loadBudget: const Duration(milliseconds: 500),
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final oldStarted = Completer<void>();
    final releaseOld = Completer<void>();
    runtime.onLoad = (plan, context, index) async {
      if (index == 0) {
        oldStarted.complete();
        await releaseOld.future;
      }
      return _loaded(context, plan);
    };

    final oldLoad = owner.load(_plan('old'));
    await tester.pump();
    expect(oldStarted.isCompleted, isTrue);
    final resolverStarted = Completer<void>();
    final resolved = Completer<PlaybackPlan?>();
    final query = owner.query((_) {
      resolverStarted.complete();
      return resolved.future;
    });
    await tester.pump();
    expect(resolverStarted.isCompleted, isTrue);

    // 模拟来源解析消耗了接受时预算的 400ms；旧原生 load 仍占着执行器。
    now = const Duration(milliseconds: 400);
    await tester.pump(now);
    resolved.complete(_plan('query'));
    var completed = false;
    unawaited(query.then((_) => completed = true));
    await tester.pump();
    now = const Duration(milliseconds: 499);
    await tester.pump(const Duration(milliseconds: 99));
    expect(completed, isFalse);
    now = const Duration(milliseconds: 500);
    await tester.pump(const Duration(milliseconds: 1));
    expect(completed, isTrue);
    final result = await query;

    expect(result.outcome, LoadOutcome.failed);
    expect(result.failure?.category, PlaybackFailureCategory.timeout);
    expect(runtime.plans.map((plan) => plan.contentKey), ['old']);

    releaseOld.complete();
    await tester.pump();
    await session.drained;
    expect(runtime.plans.map((plan) => plan.contentKey), ['old']);
    expect((await oldLoad).outcome, LoadOutcome.superseded);
    owner.close();
    expect(
      (await session.shutdown()).outcome,
      PlaybackShutdownOutcome.released,
    );
  });

  test('加载期间的新配置保留在同一请求中并应用后返回 ready', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final firstLoadStarted = Completer<void>();
    final releaseFirstLoad = Completer<void>();
    runtime.onLoad = (plan, context, index) async {
      if (index == 0) {
        firstLoadStarted.complete();
        await releaseFirstLoad.future;
      }
      return _loaded(context, plan);
    };

    final load = owner.load(_plan('movie'));
    await firstLoadStarted.future;
    expect(
      (await owner.setPlaybackSpeed(1.75)).outcome,
      CommandOutcome.accepted,
    );
    releaseFirstLoad.complete();

    final result = await load;
    expect(result.outcome, LoadOutcome.ready);
    expect(runtime.plans.map((plan) => plan.configuration.playbackSpeed), [
      1,
      1.75,
    ]);
    expect(session.currentSnapshot.configuration.applied.playbackSpeed, 1.75);
    expect(session.currentSnapshot.requestId, isNotNull);

    owner.close();
    await session.shutdown();
  });

  test('同内容来源刷新合并最近配置，不使用解析前的旧配置', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('episode'))).outcome, LoadOutcome.ready);
    expect((await owner.setPlaybackSpeed(1.5)).outcome, CommandOutcome.applied);

    final refreshed = await owner.load(
      _plan('episode', source: 'https://example.test/refresh.mp4'),
    );

    expect(refreshed.outcome, LoadOutcome.ready);
    expect(
      runtime.plans.last.source.currentVideoSource,
      'https://example.test/refresh.mp4',
    );
    expect(runtime.plans.last.configuration.playbackSpeed, 1.5);
    expect(session.currentSnapshot.configuration.applied.playbackSpeed, 1.5);

    owner.close();
    await session.shutdown();
  });

  test('命令回执不推断 actual，实际状态只接受 runtime 事实', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);
    expect(session.currentSnapshot.actual.playing, isNull);

    expect((await owner.setPlaying(true)).outcome, CommandOutcome.applied);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(session.currentSnapshot.actual.playing, isNull);

    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: false, buffering: false),
    );
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(session.currentSnapshot.actual.playing, isFalse);

    owner.close();
    await session.shutdown();
  });

  test('缺少归属或属于旧 loadId 的 EOF 不产生 completed action', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);
    final currentLoadId = session.loadId;

    runtime
      ..emitEnded(null)
      ..emitEnded(currentLoadId - 1)
      ..emitEnded(currentLoadId, runtimeId: runtime.runtimeId + 1);
    expect(session.currentSnapshot.pendingAction, isNull);
    expect(session.currentSnapshot.phase, PlaybackPhase.ready);

    runtime.emitEnded(currentLoadId);
    final completed = session.currentSnapshot.pendingAction;
    expect(completed?.kind, PlaybackActionKind.completed);
    expect(session.currentSnapshot.phase, PlaybackPhase.ended);

    owner.close();
    await session.shutdown();
  });

  test('inactive owner 返回 inactive，不能确认另一 owner 的 completed action', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('first'))).outcome, LoadOutcome.ready);
    runtime.emitEnded(session.loadId);
    final previousAction = session.currentSnapshot.pendingAction!;

    final active = session.attach();
    expect((await previous.load(_plan('stale'))).outcome, LoadOutcome.inactive);
    expect((await previous.setPlaying(true)).outcome, CommandOutcome.inactive);
    expect(
      (await active.acknowledgeAction(previousAction)).outcome,
      CommandOutcome.superseded,
    );
    expect((await active.load(_plan('second'))).outcome, LoadOutcome.ready);

    previous.close();
    active.close();
    await session.shutdown();
  });

  test('抛异常的 snapshot listener 不拖住 runtime released 和 shutdown', () async {
    final runtime = _AcceptanceRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final listenerError = Completer<Object>();
    final subscription = runZonedGuarded<StreamSubscription<PlaybackSnapshot>>(
      () => owner.snapshots.listen((_) => throw StateError('listener failed')),
      (error, _) {
        if (!listenerError.isCompleted) listenerError.complete(error);
      },
    )!;
    expect(await listenerError.future, isA<StateError>());

    owner.close();
    final result = await session.shutdown().timeout(
      const Duration(seconds: 1),
    );
    expect(result.outcome, PlaybackShutdownOutcome.released);
    expect(session.currentSnapshot.phase, PlaybackPhase.disposed);
    await subscription.cancel();
  });
}

PlaybackPlan _plan(
  String key, {
  String? source,
  PlaybackConfiguration? configuration,
}) => PlaybackPlan(
  contentKey: key,
  source: PlaybackSourceSnapshot.fromDataSource(
    NetworkSource(
      videoSource: source ?? 'https://example.test/$key.mp4',
      audioSource: null,
    ),
  ),
  timeline: const PlaybackTimeline(
    kind: PlaybackTimelineKind.onDemand,
    seekPolicy: PlaybackSeekPolicy.allowed,
    duration: Duration(minutes: 10),
  ),
  configuration: configuration ?? PlaybackConfiguration(),
);

PlaybackRuntimeLoadResult _loaded(
  PlaybackExecutionContext context,
  PlaybackPlan plan,
) => PlaybackRuntimeLoadResult(
  loaded: true,
  output: PlaybackOutputPreparation(
    strategy: PlaybackOutputStrategy.prepared,
    evidence: 'acceptance-stub-explicit-ack',
    outputEpoch: context.loadId,
    hasVideo: true,
  ),
  capabilities: const PlaybackCapabilities(
    seekSupport: PlaybackSeekSupport.supported,
    seekStart: Duration.zero,
    seekEnd: Duration(minutes: 10),
    hasVideo: true,
    hasAudio: false,
  ),
);

class _AcceptanceRuntime implements PlaybackRuntimePort {
  @override
  final int runtimeId = 73;
  @override
  Duration? position;
  @override
  bool get shaderChangeRequiresRendererReset => false;
  final StreamController<PlaybackRuntimeEvent> _events =
      StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final Completer<void> _released = Completer<void>();
  final plans = <PlaybackPlan>[];
  int _loadCount = 0;
  Future<PlaybackRuntimeLoadResult> Function(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
    int index,
  )?
  onLoad;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  void emitActual(int loadId, PlaybackActual actual) => _events.add(
    PlaybackRuntimeStateChanged(
      runtimeId: runtimeId,
      loadId: loadId,
      actual: actual,
    ),
  );

  void emitEnded(int? loadId, {int? runtimeId}) => _events.add(
    PlaybackRuntimeEnded(
      runtimeId: runtimeId ?? this.runtimeId,
      loadId: loadId,
    ),
  );

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    final index = _loadCount++;
    plans.add(plan);
    return onLoad == null
        ? _loaded(context, plan)
        : onLoad!(plan, context, index);
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> seek(
    Duration target,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setPlaybackSpeed(
    double value,
    Map<String, String> mediaOptions,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setMuted(
    bool value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setAudioTrack(
    int? trackId,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> reloadAudio(
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setSubtitleTrack(
    PlaybackSubtitleTrack? track,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setDecoder(
    PlaybackDecoder decoder,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    if (!_released.isCompleted) _released.complete();
    unawaited(_events.close());
    return const PlaybackShutdownResult.released();
  }
}
