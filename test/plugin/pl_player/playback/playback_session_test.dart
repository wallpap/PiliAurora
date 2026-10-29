import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/plugin/pl_player/playback/background_policy.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final buffering in [false, true]) {
    testWidgets('播放状态切换${buffering ? '缓冲' : '暂停'}立即冻结媒体锚点', (tester) async {
      var now = 2000000;
      final runtime = _SamplingRuntime();
      final session = PlaybackSession(
        runtime: runtime,
        mediaClockNowUs: () => now,
      );
      final owner = session.attach();
      addTearDown(owner.close);
      await tester.runAsync(
        () => owner.load(_plan('clock'), start: PlaybackStartPolicy.play),
      );
      runtime.emitActual(
        session.loadId,
        const PlaybackActual(playing: true, buffering: false),
      );
      const anchor = PlaybackMediaAnchor(
        positionUs: 1000000,
        observedAtUs: 2000000,
        effectiveRate: 1,
        advancing: true,
        ready: true,
        continuity: 1,
        validForUs: 500000,
      );
      void emitAnchor(PlaybackMediaAnchor value) => runtime._events.add(
        PlaybackRuntimeMediaAnchor(
          runtimeId: runtime.runtimeId,
          loadId: session.loadId,
          seekSequence: 0,
          anchor: value,
        ),
      );
      emitAnchor(anchor);
      expect(session.currentMediaAnchor!.advancing, isTrue);
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(fontSize: 20, duration: 8, safeArea: false),
        size: const Size(320, 120),
      );
      addTearDown(renderer.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 320,
              height: 120,
              child: DanmakuWindowScreen<void>(
                renderer: renderer,
                clock: session,
                size: const Size(320, 120),
                monotonicUs: () => now,
                frameTimeUs: () => now,
                prepareFrame: (r, p, {required effectiveRate}) {
                  if (r.validUntilUs != r.validFromUs) return;
                  r.prepare(
                    [
                      DanmakuWindowContent(
                        'scroll',
                        r.validFromUs,
                        DanmakuContentItem<void>('state'),
                      ),
                    ],
                    generation: r.generation,
                    preparedUntilUs: r.validFromUs + 10000000,
                  );
                },
              ),
            ),
          ),
        ),
      );
      now += 25000;
      await tester.pump(const Duration(microseconds: 25000));
      final stoppedAt = renderer.presentationTimeUs;
      runtime.emitActual(
        session.loadId,
        PlaybackActual(playing: buffering, buffering: buffering),
      );
      expect(session.currentMediaAnchor!.advancing, isFalse);
      final frozen = session.currentMediaAnchor!;
      expect(frozen.positionUs, 1025000);
      expect(frozen.observedAtUs, now);
      expect(frozen.positionAt(9000000), frozen.positionUs);
      expect(renderer.presentationTimeUs, stoppedAt);
      await tester.pump();
      expect(renderer.presentationTimeUs, stoppedAt);
      expect(tester.hasRunningAnimations, isFalse);
      // 状态切换前的 worker 结果迟到时，暂停不能被旧采样撤销。
      emitAnchor(anchor);
      emitAnchor(
        const PlaybackMediaAnchor(
          positionUs: 1040000,
          observedAtUs: 2040000,
          effectiveRate: 1,
          advancing: true,
          ready: true,
          continuity: 1,
          validForUs: 500000,
        ),
      );
      expect(session.currentMediaAnchor!.advancing, isFalse);
      expect(session.currentMediaAnchor!.positionUs, frozen.positionUs);
      var samples = 0;
      runtime.onSample = () => samples++;
      now += 1000000;
      await tester.pump(const Duration(seconds: 1));
      expect(renderer.presentationTimeUs, stoppedAt);
      runtime.emitActual(
        session.loadId,
        const PlaybackActual(playing: true, buffering: false),
      );
      expect(samples, 1);
      expect(session.currentMediaAnchor!.advancing, isFalse);
      expect(session.currentMediaAnchor!.positionUs, frozen.positionUs);
      expect(tester.hasRunningAnimations, isFalse);
      // 暂停期间的读取结果在恢复后返回，也不能包含暂停时长的外推。
      emitAnchor(anchor);
      expect(session.currentMediaAnchor!.advancing, isFalse);
      final resumed = PlaybackMediaAnchor(
        positionUs: frozen.positionUs,
        observedAtUs: now,
        effectiveRate: 1,
        advancing: true,
        ready: true,
        continuity: 1,
        validForUs: 500000,
      );
      emitAnchor(resumed);
      expect(session.currentMediaAnchor, same(resumed));
      expect(session.currentMediaAnchor!.positionAt(now + 20000), 1045000);
      now += 20000;
      await tester.pump(const Duration(milliseconds: 20));
      expect(renderer.presentationTimeUs, 1045000);
      await tester.pumpWidget(const SizedBox.shrink());
      owner.close();
      await tester.pump();
      expect(session.isDisposed, isTrue);
    });
  }

  test('暂停加载进入 ready 后主动取得首个媒体锚点', () async {
    final runtime = _SamplingRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    const anchor = PlaybackMediaAnchor(
      positionUs: 0,
      observedAtUs: 1000000,
      effectiveRate: 1,
      advancing: false,
      ready: true,
      continuity: 1,
      validForUs: 500000,
    );
    runtime.onSample = () => runtime._events.add(
      PlaybackRuntimeMediaAnchor(
        runtimeId: runtime.runtimeId,
        loadId: session.loadId,
        seekSequence: 0,
        anchor: anchor,
      ),
    );
    await owner.load(_plan('paused'), start: PlaybackStartPolicy.pause);
    expect(session.currentMediaAnchor, same(anchor));
    owner.close();
    await runtime.released;
  });

  test('seek 等待原生资格时暂停可执行，较新目标替换旧等待', () async {
    final runtime = _GatedRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('gate'), start: PlaybackStartPolicy.play);
    final first = owner.seek(const Duration(seconds: 2));
    expect((await owner.setPlaying(false)).outcome, CommandOutcome.applied);
    final second = owner.seek(const Duration(seconds: 3));
    expect((await first).outcome, CommandOutcome.superseded);
    expect(runtime.seekCalls, isEmpty);
    runtime.unblock();
    expect((await second).outcome, CommandOutcome.applied);
    expect(runtime.seekCalls, [const Duration(seconds: 3)]);
    owner.close();
    await runtime.released;
  });

  test('seek 资格等待超时释放订阅，迟到完成仍可开启后续提交', () async {
    final runtime = _GatedRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      commandBudget: const Duration(milliseconds: 30),
    );
    final owner = session.attach();
    await owner.load(_plan('gate'), start: PlaybackStartPolicy.play);
    final result = await owner.seek(const Duration(seconds: 2));
    expect(result.outcome, CommandOutcome.failed);
    expect(result.failure?.category, PlaybackFailureCategory.timeout);
    expect(runtime.changes.hasListener, isFalse);
    expect(runtime.seekCalls, isEmpty);
    runtime.unblock();
    expect(
      (await owner.seek(const Duration(seconds: 3))).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.changes.hasListener, isFalse);
    owner.close();
    await runtime.released;
  });

  test('关闭使外部 seek 等待立即结束，无需原生落点完成', () async {
    final runtime = _GatedRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('gate'), start: PlaybackStartPolicy.play);
    final seek = owner.seek(const Duration(seconds: 2));
    owner.close();
    expect((await seek).outcome, CommandOutcome.superseded);
    await runtime.released;
    expect(runtime.seekCalls, isEmpty);
  });

  test('媒体时钟独立发布，丢弃其他 runtime、旧加载和旧 seek 的采样', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('clock'), start: PlaybackStartPolicy.play);
    final samples = <PlaybackMediaAnchor?>[];
    final subscription = session.mediaAnchors.listen(samples.add);
    const anchor = PlaybackMediaAnchor(
      positionUs: 1000000,
      observedAtUs: 2000000,
      effectiveRate: 1,
      advancing: true,
      ready: true,
      continuity: 1,
      validForUs: 500000,
    );
    void emit({int? runtimeId, int? loadId, int sequence = 0}) {
      runtime._events.add(
        PlaybackRuntimeMediaAnchor(
          runtimeId: runtimeId ?? runtime.runtimeId,
          loadId: loadId ?? session.loadId,
          seekSequence: sequence,
          anchor: anchor,
        ),
      );
    }

    final version = session.currentSnapshot.snapshotVersion;
    emit(runtimeId: -1);
    emit(loadId: session.loadId - 1);
    expect(samples, isEmpty);
    emit();
    expect(session.currentMediaAnchor, same(anchor));
    expect(session.currentSnapshot.snapshotVersion, version);
    await owner.seek(const Duration(seconds: 2));
    expect(session.currentMediaAnchor, isNull);
    emit();
    expect(samples, [anchor, null]);
    emit(sequence: 1);
    expect(session.currentMediaAnchor, same(anchor));
    final next = session.attach();
    expect(session.currentMediaAnchor, isNull);
    emit(sequence: 1);
    expect(samples, [anchor, null, anchor, null]);
    await subscription.cancel();
    owner.close();
    next.close();
    await runtime.released;
  });

  test('加载期间进入后台抑制后续播放，切换 owner 后仍保持策略', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final policy = PlaybackBackgroundPolicy(
      session: session,
      continuePlaying: false,
    );
    addTearDown(() {
      policy.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final first = session.attach();
    final pending = Completer<PlaybackPlan?>();
    final result = first.query(
      (_) => pending.future,
      start: PlaybackStartPolicy.play,
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pending.complete(_plan('first'));
    expect((await result).outcome, LoadOutcome.ready);
    expect(runtime.playCalls, [false]);
    final second = session.attach();
    await second.load(_plan('second'), start: PlaybackStartPolicy.play);
    expect(runtime.playCalls.last, isFalse);
    expect(session.currentSnapshot.inhibitors, hasLength(1));
    policy.continuePlaying = true;
    await _until(() => runtime.playCalls.last);
    expect(runtime.playCalls.last, isTrue);
    expect(session.currentSnapshot.inhibitors, isEmpty);
    policy.continuePlaying = false;
    await _until(() => !runtime.playCalls.last);
    expect(runtime.playCalls.last, isFalse);
    await second.setPlaying(false);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(runtime.playCalls.last, isFalse);
    expect(session.currentSnapshot.inhibitors, isEmpty);
    first.close();
    second.close();
    await runtime.released;
  });

  test('直播候选确认无视频轨后立即尝试下一源，保留请求和播放意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    runtime.onLoad = (plan, context, index) async =>
        index == 0 ? _audioLoaded(context) : _loaded(context, plan);
    final result = await owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/audio.flv',
          'https://example.test/video.flv',
        ],
      ),
      start: PlaybackStartPolicy.play,
    );
    expect(result.outcome, LoadOutcome.ready);
    expect(runtime.loadedPlans.map((p) => p.source.videoIndex), [0, 1]);
    expect(runtime.playCalls, [true]);
    expect(session.currentSnapshot.requestId, 1);
    expect(session.currentSnapshot.loadId, 2);
    expect(session.currentPlan?.source.videoIndex, 1);
    owner.close();
    await runtime.released;
  });

  test('直播全部候选无视频轨时失败并停止重试', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    runtime.onLoad = (plan, context, index) async => _audioLoaded(context);
    final result = await owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/one.flv',
          'https://example.test/two.flv',
        ],
      ),
    );
    expect(result.outcome, LoadOutcome.failed);
    expect(result.failure?.operation, 'validate-live-video');
    expect(runtime.loadedPlans, hasLength(2));
    expect(runtime.playCalls, isEmpty);
    owner.close();
    await runtime.released;
  });

  test('直播轮换候选期间的暂停与新媒体请求仍优先生效', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final secondStarted = Completer<void>();
    final secondFinished = Completer<void>();
    runtime.onLoad = (plan, context, index) async {
      if (index == 0) return _audioLoaded(context);
      if (index == 1) {
        secondStarted.complete();
        await secondFinished.future;
      }
      return _loaded(context, plan);
    };
    final live = owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/one.flv',
          'https://example.test/two.flv',
        ],
      ),
      start: PlaybackStartPolicy.play,
    );
    await secondStarted.future;
    await owner.setPlaying(false);
    final latest = owner.load(
      _plan('latest'),
      start: PlaybackStartPolicy.preserve,
    );
    expect((await live).outcome, LoadOutcome.superseded);
    secondFinished.complete();
    expect((await latest).outcome, LoadOutcome.ready);
    expect(session.currentPlan?.contentKey, 'latest');
    expect(runtime.playCalls, [false]);
    owner.close();
    await runtime.released;
  });

  for (final live in [false, true]) {
    test('允许${live ? '显式纯音频直播' : '纯音频点播'}的无视频输出', () async {
      final runtime = _FakeRuntime();
      final session = PlaybackSession(runtime: runtime);
      final owner = session.attach();
      runtime.onLoad = (plan, context, index) async => _audioLoaded(context);
      final result = await owner.load(
        _plan(
          'audio',
          kind: live
              ? PlaybackTimelineKind.live
              : PlaybackTimelineKind.onDemand,
          audioOnly: live,
        ),
      );
      expect(result.outcome, LoadOutcome.ready);
      expect(runtime.loadedPlans, hasLength(1));
      owner.close();
      await runtime.released;
    });
  }

  test('查询成功后业务回写仍属于当前媒体，下一次加载使其失效', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime, monotonicNow: () => now);
    final owner = session.attach();
    late PlaybackQuery query;
    final loaded = await owner.query((accepted) async {
      query = accepted;
      return _plan('online-video');
    }, start: PlaybackStartPolicy.play);
    expect(loaded.outcome, LoadOutcome.ready);
    expect(query.isCurrent, isTrue, reason: '页面在 ready 后才挂载视频和字幕');
    now = const Duration(minutes: 1);
    expect(query.isCurrent, isTrue, reason: '成功加载后的回写不再受加载 deadline 限制');
    await owner.load(_plan('next-video'));
    expect(query.isCurrent, isFalse);
    late PlaybackQuery current;
    await owner.query((accepted) async {
      current = accepted;
      return _plan('next-video');
    });
    expect(current.isCurrent, isTrue);
    owner.invalidateRequests();
    expect(current.isCurrent, isFalse);
    owner.close();
    await session.shutdown();
  });

  test('新加载立即结算旧请求，但等旧原生调用排空后才执行新加载', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final oldOpen = Completer<void>();
    final oldStarted = Completer<void>();
    final calls = <String>[];
    runtime.onLoad = (plan, context, index) async {
      calls.add(plan.contentKey);
      if (index == 0) {
        oldStarted.complete();
        await oldOpen.future;
      }
      return _loaded(context, plan);
    };

    final old = owner.load(_plan('old'));
    await oldStarted.future;
    final latest = owner.load(_plan('latest'));
    expect((await old).outcome, LoadOutcome.superseded);
    expect(calls, ['old']);

    oldOpen.complete();
    expect((await latest).outcome, LoadOutcome.ready);
    expect(calls, ['old', 'latest']);

    owner.close();
    final shutdown = await session.shutdown();
    expect(shutdown.outcome, PlaybackShutdownOutcome.released);
    expect(session.currentSnapshot.phase, PlaybackPhase.disposed);
  });

  testWidgets('播放调用在原生写入未返回时也应按命令预算结束等待', (tester) async {
    var now = Duration.zero;
    const budget = Duration(milliseconds: 500);
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      commandBudget: budget,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final load = owner.load(_plan('movie'));
    await tester.pump();
    expect((await load).outcome, LoadOutcome.ready);
    final nativeReply = Completer<PlaybackRuntimeCommandResult>();
    runtime.onSetPlaying = (playing, context, _) {
      runtime.playCalls.add(playing);
      return nativeReply.future;
    };
    addTearDown(() async {
      if (!nativeReply.isCompleted) {
        nativeReply.complete(const PlaybackRuntimeCommandResult());
      }
      await tester.pump();
      owner.close();
      await tester.pump();
      await session.shutdown();
    });
    CommandResult? result;
    unawaited(owner.setPlaying(true).then((value) => result = value));
    await tester.pump();
    now = budget;
    await tester.pump(budget);
    expect(result, isNotNull, reason: 'commandBudget 到达后播放调用仍未结算');
    expect(result!.failure?.category, PlaybackFailureCategory.timeout);
    CommandResult? pauseResult;
    unawaited(owner.setPlaying(false).then((value) => pauseResult = value));
    await tester.pump();
    now += budget;
    await tester.pump(budget);
    expect(pauseResult?.failure?.category, PlaybackFailureCategory.timeout);
    expect(runtime.playCalls, [false, true]);
    nativeReply.complete(const PlaybackRuntimeCommandResult());
    await tester.pump();
    expect(runtime.playCalls, [false, true, false]);
    expect(result!.failure?.category, PlaybackFailureCategory.timeout);
    expect(session.currentSnapshot.intent.playing, isFalse);
  });

  test('旧 play 写入返回后 writer 收敛到更新的 pause 意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    final oldPlay = Completer<PlaybackRuntimeCommandResult>();
    final playStarted = Completer<void>();
    runtime.onSetPlaying = (playing, context, index) {
      runtime.playCalls.add(playing);
      if (playing && index == 1) {
        playStarted.complete();
        return oldPlay.future;
      }
      return Future.value(const PlaybackRuntimeCommandResult());
    };

    final play = owner.setPlaying(true);
    await playStarted.future;
    final pause = owner.setPlaying(false);
    oldPlay.complete(const PlaybackRuntimeCommandResult());

    expect((await play).outcome, CommandOutcome.superseded);
    expect((await pause).outcome, CommandOutcome.applied);
    expect(runtime.playCalls, [false, true, false]);
    expect(session.currentSnapshot.intent.playing, isFalse);
    expect(session.currentSnapshot.actual.playing, isNull);

    owner.close();
    await runtime.released;
  });

  test('异步 query 被新请求取代后不能提交迟到计划', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final oldResolver = Completer<PlaybackPlan?>();
    final oldStarted = Completer<void>();
    runtime.onLoad = (plan, context, _) async => _loaded(context, plan);

    final old = owner.query((query) {
      oldStarted.complete();
      return oldResolver.future;
    });
    await oldStarted.future;
    final latest = owner.load(_plan('latest'));
    expect((await old).outcome, LoadOutcome.superseded);
    oldResolver.complete(_plan('late'));

    expect((await latest).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['latest']);
    owner.close();
    await runtime.released;
  });

  test('owner返回后须提交自己的load才恢复旧播放意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);
    final routeToken = previous.acquireInhibitor(
      PlaybackInhibitorSource.system,
    );
    expect(routeToken, isNotNull);
    await _until(() => !runtime.playCalls.last);

    final next = session.attach();
    expect((await next.load(_plan('next'))).outcome, LoadOutcome.ready);
    await next.setPlaying(true);
    await _until(() => runtime.playCalls.last);

    next.close();
    await _until(() => !runtime.playCalls.last);
    expect(previous.isActive, isFalse);

    previous.activate();
    expect(previous.isActive, isTrue);
    await _until(() => !runtime.playCalls.last);
    expect(
      (await previous.releaseInhibitor(routeToken!)).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.playCalls.last, isFalse);
    expect((await previous.setPlaying(true)).outcome, CommandOutcome.noMedia);
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await _until(() => runtime.playCalls.last);

    previous.close();
    await runtime.released;
  });

  for (final ended in [false, true]) {
    test('A${ended ? '播完' : '暂停'}后经过B/C/D返回仍保持停止，显式播放可恢复', () async {
      final runtime = _FakeRuntime();
      final session = PlaybackSession(runtime: runtime);
      final a = session.attach();
      await a.load(_plan('A'), start: PlaybackStartPolicy.play);
      if (ended) {
        runtime._events.add(
          PlaybackRuntimeEnded(
            runtimeId: runtime.runtimeId,
            loadId: session.loadId,
          ),
        );
        expect(session.currentSnapshot.phase, PlaybackPhase.ended);
      } else {
        await a.setPlaying(false);
      }
      final token = a.acquireInhibitor(PlaybackInhibitorSource.system)!;
      final pages = <PlaybackOwner>[];
      for (final key in ['B', 'C', 'D']) {
        final owner = session.attach();
        pages.add(owner);
        await owner.load(_plan(key), start: PlaybackStartPolicy.play);
      }
      for (final owner in pages.reversed) {
        owner.close();
      }
      a.activate();
      await a.load(_plan('A'));
      await a.releaseInhibitor(token);
      expect(session.currentSnapshot.intent.playing, isFalse);
      expect(runtime.playCalls.last, isFalse);
      await a.setPlaying(true);
      expect(runtime.playCalls.last, isTrue);
      a.close();
      await runtime.released;
    });
  }

  test('页面关闭但媒体租约尚未释放时，原生播放器立即暂停', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('movie'), start: PlaybackStartPolicy.play);
    final lease = owner.acquireKeepAlive()!;
    expect(runtime.playCalls.last, isTrue);

    owner.close();
    await _until(() => !runtime.playCalls.last);
    expect(session.isDisposed, isFalse);

    lease.close();
    await runtime.released;
    expect(session.isDisposed, isTrue);
  });

  test('关闭inactive owner不影响当前活动owner的播放', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);

    final active = session.attach();
    expect((await active.load(_plan('next'))).outcome, LoadOutcome.ready);
    await active.setPlaying(true);
    await _until(() => runtime.playCalls.last);

    previous.close();
    expect(active.isActive, isTrue);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls.last, isTrue);

    active.close();
    await runtime.released;
  });

  test('session audio focus抑制跨owner load并按新owner最新意图恢复', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);

    final focusToken = session.acquireSessionInhibitor(
      PlaybackInhibitorSource.audioFocus,
    );
    expect(focusToken, isNotNull);
    await _until(() => !runtime.playCalls.last);

    final active = session.attach();
    expect(
      (await active.load(
        _plan('next'),
        start: PlaybackStartPolicy.play,
      )).outcome,
      LoadOutcome.ready,
    );
    expect(active.isActive, isTrue);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls.last, isFalse);

    expect((await active.setPlaying(false)).outcome, CommandOutcome.applied);
    expect(
      (await session.releaseSessionInhibitor(focusToken!)).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.playCalls.last, isFalse);

    expect((await active.setPlaying(true)).outcome, CommandOutcome.applied);
    await _until(() => runtime.playCalls.last);

    active.close();
    previous.close();
    await runtime.released;
  });

  test('snapshot 新订阅即时给当前值，暂停期间只保留 latest', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final received = <PlaybackSnapshot>[];
    final firstSnapshot = Completer<void>();
    final subscription = owner.snapshots.listen((snapshot) {
      received.add(snapshot);
      if (!firstSnapshot.isCompleted) firstSnapshot.complete();
    });
    await firstSnapshot.future;
    expect(
      received.single.snapshotVersion,
      session.currentSnapshot.snapshotVersion,
    );

    subscription.pause();
    final tokens = <PlaybackInhibitorToken>[];
    for (var i = 0; i < 20; i++) {
      tokens.add(owner.acquireInhibitor(PlaybackInhibitorSource.system)!);
    }
    for (final token in tokens) {
      await owner.releaseInhibitor(token);
    }
    final versionBeforeResume = session.currentSnapshot.snapshotVersion;
    final countBeforeResume = received.length;
    subscription.resume();
    await _until(() => received.length > countBeforeResume);
    expect(received.length, countBeforeResume + 1);
    expect(received.last.snapshotVersion, versionBeforeResume);

    await subscription.cancel();
    owner.close();
    await runtime.released;
  });

  test('seek 受 timeline 与已知区间约束', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    expect(
      (await owner.seek(const Duration(seconds: -1))).outcome,
      CommandOutcome.outOfRange,
    );
    expect(
      (await owner.seek(const Duration(seconds: 11))).outcome,
      CommandOutcome.outOfRange,
    );
    expect(
      (await owner.seek(const Duration(seconds: 10))).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.seekCalls, [const Duration(seconds: 10)]);

    owner.close();
    await runtime.released;
  });

  test('不可 seek 直播的 shader 重建走同一加载协议并保留 request 与播放意图', () async {
    final runtime = _FakeRuntime()..shaderChangeRequiresRendererReset = true;
    final session = PlaybackSession(
      runtime: runtime,
      commandBudget: Duration.zero,
    );
    final owner = session.attach();
    expect(
      (await owner.load(
        _plan(
          'live',
          kind: PlaybackTimelineKind.live,
          seekPolicy: PlaybackSeekPolicy.unknown,
        ),
        start: PlaybackStartPolicy.play,
      )).outcome,
      LoadOutcome.ready,
    );
    final requestId = session.requestId;
    final previousLoadId = session.loadId;

    expect(
      (await owner.setShader(['quality'])).outcome,
      CommandOutcome.applied,
    );
    expect(session.requestId, requestId);
    expect(session.loadId, previousLoadId + 1);
    expect(runtime.loadedPlans, hasLength(2));
    expect(runtime.loadedPlans.last.configuration.shaders, ['quality']);
    expect(runtime.loadedPlans.last.startPosition, isNull);
    expect(runtime.loadedPlans.last.reloadPosition, isNull);
    expect(runtime.shaderCalls, isEmpty);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls, [true, false, true]);

    owner.close();
    await runtime.released;
  });

  test('不可 seek 直播的解码器和音频模式改动经加载协议应用', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect(
      (await owner.load(
        _plan(
          'live',
          kind: PlaybackTimelineKind.live,
          seekPolicy: PlaybackSeekPolicy.unknown,
        ),
      )).outcome,
      LoadOutcome.ready,
    );

    expect(
      (await owner.setDecoder(const PlaybackDecoder('no'))).outcome,
      CommandOutcome.applied,
    );
    expect((await owner.setAudioOnly(true)).outcome, CommandOutcome.applied);
    expect(
      (await owner.setPlaybackSpeed(
        1.5,
        mediaOptions: const {'cache-secs': '5'},
      )).outcome,
      CommandOutcome.applied,
    );

    expect(runtime.loadedPlans, hasLength(3));
    expect(runtime.loadedPlans[1].configuration.hwdec, 'no');
    expect(runtime.loadedPlans[1].configuration.audioOnly, isFalse);
    expect(runtime.loadedPlans[2].configuration.hwdec, 'no');
    expect(runtime.loadedPlans[2].configuration.audioOnly, isTrue);
    expect(runtime.decoderCalls, isEmpty);
    expect(runtime.audioOnlyCalls, isEmpty);

    owner.close();
    await runtime.released;
  });

  test('可 seek 点播的 shader、解码器和音频模式原位更新', () async {
    final runtime = _FakeRuntime()..shaderChangeRequiresRendererReset = true;
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    expect(
      (await owner.setShader(['quality'])).outcome,
      CommandOutcome.applied,
    );
    expect(
      (await owner.setDecoder(const PlaybackDecoder('no'))).outcome,
      CommandOutcome.applied,
    );
    expect((await owner.setAudioOnly(true)).outcome, CommandOutcome.applied);

    expect(runtime.loadedPlans, hasLength(1));
    expect(runtime.shaderCalls, [
      ['quality'],
    ]);
    expect(runtime.decoderCalls, ['no']);
    expect(runtime.audioOnlyCalls, [true]);
    expect(
      (await owner.setPlaybackSpeed(
        1.5,
        mediaOptions: const {'cache-secs': '5'},
      )).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.speedCalls.single.speed, 1.5);
    expect(runtime.speedCalls.single.mediaOptions, {'cache-secs': '5'});
    expect(session.currentSnapshot.configuration.applied.shaders, ['quality']);
    expect(
      session.currentSnapshot.configuration.applied.mediaOptions,
      {'cache-secs': '5'},
    );

    owner.close();
    await runtime.released;
  });

  test('音轨重连经过会话命令，保留视频代次、暂停意图和音量', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('movie'), start: PlaybackStartPolicy.pause);
    await owner.setVolume(37);
    final snapshot = session.currentSnapshot;
    expect((await owner.reloadAudio()).outcome, CommandOutcome.applied);
    expect(runtime.audioReloadContexts, hasLength(1));
    expect(runtime.audioReloadContexts.single.loadId, snapshot.loadId);
    expect(runtime.loadedPlans, hasLength(1));
    expect(session.currentSnapshot.loadId, snapshot.loadId);
    expect(session.currentSnapshot.intent.playing, isFalse);
    expect(session.currentSnapshot.configuration.desired.volume, 37);
    expect(runtime.seekCalls, isEmpty);
    owner.close();
    await session.shutdown();
  });

  test('手动播放前仅解析来源正常结束，保留查询身份且不标记失败', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    late PlaybackQuery query;
    final result = await owner.query(
      (value) async {
        query = value;
        return _plan('manual');
      },
      start: PlaybackStartPolicy.pause,
      shouldLoad: () => false,
    );
    expect(result.outcome, LoadOutcome.noMedia);
    expect(session.currentSnapshot.phase, PlaybackPhase.idle);
    expect(session.currentSnapshot.failure, isNull);
    expect(runtime.loadedPlans, isEmpty);
    expect(query.isCurrent, isTrue);
    await owner.load(_plan('manual'), start: PlaybackStartPolicy.play);
    expect(query.isCurrent, isFalse);
    expect(runtime.loadedKeys, ['manual']);
    owner.close();
    await session.shutdown();
  });

  test('来源查询未返回时点击播放，查询完成后加载并落实最新意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final source = Completer<PlaybackPlan>();
    var load = false;
    final query = owner.query(
      (_) => source.future,
      start: PlaybackStartPolicy.pause,
      shouldLoad: () => load,
    );
    load = true;
    await owner.setPlaying(true);
    source.complete(_plan('manual'));
    expect((await query).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['manual']);
    expect(runtime.playCalls.last, isTrue);
    owner.close();
    await session.shutdown();
  });

  test('音轨重连中切源使旧结果失效，原生命令排空后再加载新媒体', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    runtime.onReloadAudio = (_) => pending.future;
    addTearDown(() async {
      if (!pending.isCompleted) {
        pending.complete(const PlaybackRuntimeCommandResult());
      }
      owner.close();
      await session.shutdown();
    });
    await owner.load(_plan('first'));
    final repair = owner.reloadAudio();
    await _until(() => runtime.audioReloadContexts.isNotEmpty);
    final nextLoad = owner.load(_plan('second'));
    expect((await repair).outcome, CommandOutcome.superseded);
    expect(runtime.audioReloadContexts.single.isCurrent(), isFalse);
    expect(runtime.loadedKeys, ['first']);
    pending.complete(const PlaybackRuntimeCommandResult());
    expect((await nextLoad).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['first', 'second']);
    expect(session.currentPlan?.contentKey, 'second');
  });

  test('地址重新解析时暂停旧媒体，失败后保持静音与用户意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    addTearDown(() async {
      owner.close();
      await runtime.released;
    });
    await owner.load(_plan('movie'), start: PlaybackStartPolicy.play);
    final resolving = Completer<PlaybackPlan?>();
    final query = owner.query((_) => resolving.future);
    await _until(() => !runtime.playCalls.last);
    expect(session.currentSnapshot.phase, PlaybackPhase.loading);
    expect(session.currentSnapshot.intent.playing, isTrue);
    resolving.complete(null);
    expect((await query).outcome, LoadOutcome.failed);
    expect(runtime.playCalls.last, isFalse);
    expect(session.currentSnapshot.intent.playing, isTrue);
  });

  test('运行时失败使迟到的 play 收敛到暂停', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final playing = Completer<void>();
    final started = Completer<void>();
    addTearDown(() async {
      if (!playing.isCompleted) playing.complete();
      owner.close();
      await runtime.released;
    });
    await owner.load(_plan('movie'));
    runtime.onSetPlaying = (value, context, index) async {
      if (value) {
        started.complete();
        await playing.future;
      }
      runtime.playCalls.add(value);
      return const PlaybackRuntimeCommandResult();
    };
    final command = owner.setPlaying(true);
    await started.future;
    runtime._events.add(
      PlaybackRuntimeFailure(
        runtimeId: runtime.runtimeId,
        loadId: session.loadId,
        failure: const PlaybackFailure(
          category: PlaybackFailureCategory.source,
          operation: 'read',
          stage: PlaybackStage.observing,
          recoverable: true,
          cause: 'source-failed',
        ),
      ),
    );
    playing.complete();
    await command;
    await _until(() => runtime.playCalls.length >= 3);
    expect(runtime.playCalls.last, isFalse);
    expect(session.currentSnapshot.phase, PlaybackPhase.failed);
  });

  test('重新加载中用户暂停，输出就绪后保持暂停', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    addTearDown(() async {
      owner.close();
      await runtime.released;
    });
    await owner.load(_plan('movie'), start: PlaybackStartPolicy.play);
    final resolving = Completer<PlaybackPlan?>();
    final query = owner.query((_) => resolving.future);
    await _until(() => !runtime.playCalls.last);
    await owner.setPlaying(false);
    resolving.complete(_plan('movie'));
    expect((await query).outcome, LoadOutcome.ready);
    expect(runtime.playCalls.last, isFalse);
    expect(session.currentSnapshot.intent.playing, isFalse);
  });

  test('同页切来源及地址查询完成后从最新位置续播', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final plan = _plan('movie');
    await owner.load(plan, start: PlaybackStartPolicy.play);
    runtime.position = const Duration(milliseconds: 123456);
    await owner.load(plan.withSource(_plan('cdn').source));
    expect(runtime.loadedPlans.last.startPosition, runtime.position);

    final resolving = Completer<PlaybackPlan?>();
    final query = owner.query((_) => resolving.future);
    runtime.position = const Duration(milliseconds: 125678);
    resolving.complete(plan);
    await query;
    expect(runtime.loadedPlans.last.startPosition, runtime.position);
    owner.close();
    await runtime.released;
  });

  test('重载失败清零后连续重试保留续播位置，seek 后使用新的当前位置', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final plan = _plan('movie');
    await owner.load(plan, start: PlaybackStartPolicy.play);
    runtime.position = const Duration(milliseconds: 123456);
    runtime.onLoad = (plan, context, index) async {
      runtime.position = Duration.zero;
      return _failedLoad(context);
    };
    await owner.retry();
    await owner.retry();
    expect(
      runtime.loadedPlans.last.startPosition,
      const Duration(milliseconds: 123456),
    );
    runtime.onLoad = null;
    await owner.retry();
    runtime.position = const Duration(seconds: 10);
    await owner.retry();
    expect(runtime.loadedPlans.last.startPosition, const Duration(seconds: 10));
    owner.close();
    await runtime.released;
  });

  test('新内容首次加载失败后可重试，使用失败内容的来源与起播位置', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    await owner.load(_plan('old'));
    runtime.position = const Duration(seconds: 99);
    runtime.onLoad = (plan, context, index) async {
      runtime.position = Duration.zero;
      return _failedLoad(context);
    };
    await owner.load(_plan('new'));
    runtime.onLoad = null;
    expect((await owner.retry()).outcome, LoadOutcome.ready);
    expect(runtime.loadedPlans.last.contentKey, 'new');
    expect(runtime.loadedPlans.last.startPosition, isNull);
    owner.close();
    await runtime.released;
  });

  test('自动恢复从当前播放位置继续，保留当前配置和来源候选', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final plan = _plan('movie');
    await owner.load(plan, start: PlaybackStartPolicy.play);
    await owner.setVolume(37);
    runtime
      ..emitActual(
        session.loadId,
        const PlaybackActual(
          playing: true,
          position: Duration(seconds: 1),
        ),
      )
      // 原生进度持续变化时不会为每一帧发布规范状态快照。
      ..position = const Duration(milliseconds: 867600);
    expect((await owner.recover(plan)).outcome, LoadOutcome.ready);
    final reloaded = runtime.loadedPlans.last;
    expect(reloaded.startPosition, const Duration(milliseconds: 867600));
    expect(reloaded.reloadPosition, const Duration(milliseconds: 867600));
    expect(reloaded.configuration.volume, 37);
    expect(reloaded.source, same(plan.source));
    owner.close();
    await session.shutdown();
  });

  test('延期恢复在执行时捕获新位置，直播恢复不携带位置', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final plan = _plan('movie');
    await owner.load(plan, start: PlaybackStartPolicy.play);
    await owner.setPlaying(false);
    expect((await owner.recover(plan)).outcome, LoadOutcome.deferred);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(
        playing: false,
        position: Duration(seconds: 8),
      ),
    );
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(
        playing: true,
        videoProgressing: false,
        position: Duration(seconds: 8),
      ),
    );
    await _until(() => runtime.loadedPlans.length == 2);
    expect(runtime.loadedPlans.last.reloadPosition, const Duration(seconds: 8));
    await _until(() => session.currentSnapshot.phase == PlaybackPhase.ready);
    final live = _plan('live', kind: PlaybackTimelineKind.live);
    await owner.load(live, start: PlaybackStartPolicy.play);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, position: Duration(seconds: 500)),
    );
    await owner.recover(live);
    expect(runtime.loadedPlans.last.startPosition, isNull);
    expect(runtime.loadedPlans.last.reloadPosition, isNull);
    owner.close();
    await session.shutdown();
  });

  test('暂停期间恢复延期，恢复用户播放意图后才提交加载', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);

    expect((await owner.recover(plan)).outcome, LoadOutcome.deferred);
    expect(runtime.loadedKeys, ['movie']);

    now = const Duration(seconds: 40);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runtime.loadedKeys, ['movie', 'movie']);
    expect(session.currentSnapshot.phase, PlaybackPhase.ready);

    owner.close();
    await session.shutdown();
  });

  test('恢复预算跨 loadId 累计，连续健康十秒后才重置', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );

    for (var i = 0; i < 3; i++) {
      final result = await owner.recover(plan);
      expect(
        result.outcome,
        LoadOutcome.ready,
        reason: 'recovery attempt $i: ${result.failure?.cause}',
      );
    }
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie']);

    now = const Duration(seconds: 1);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: true),
    );
    now = const Duration(seconds: 11);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: true),
    );

    expect((await owner.recover(plan)).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie', 'movie']);

    owner.close();
    await session.shutdown();
  });

  test('连续故障恢复预算按有效播放时间耗尽，不因经过三十秒自动重开', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );

    for (var i = 0; i < 3; i++) {
      expect((await owner.recover(plan)).outcome, LoadOutcome.ready);
    }
    now = const Duration(seconds: 30);
    final exhausted = await owner.recover(plan);
    expect(exhausted.outcome, LoadOutcome.failed);
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie']);

    owner.close();
    await session.shutdown();
  });

  test('shutdown deadline可先结算cleanupIncomplete，released迟到后仍完成资源释放', () async {
    final runtime = _FakeRuntime()
      ..onShutdown = () async => const PlaybackShutdownResult.cleanupIncomplete(
        PlaybackFailure(
          category: PlaybackFailureCategory.timeout,
          operation: 'shutdown',
          stage: PlaybackStage.closing,
          recoverable: false,
          cause: 'fake delayed release',
        ),
      );
    final session = PlaybackSession(runtime: runtime);
    session.attach().close();
    final result = await session.shutdown();
    expect(result.outcome, PlaybackShutdownOutcome.cleanupIncomplete);
    expect(session.currentSnapshot.phase, PlaybackPhase.closing);

    runtime.completeRelease();
    await _until(() => session.currentSnapshot.phase == PlaybackPhase.disposed);
  });

  test('shutdown 不因暂停的 snapshot stream 拖住原生 released', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final subscription = owner.snapshots.listen((_) {})..pause();

    owner.close();
    final shutdown = await session.shutdown().timeout(
      const Duration(seconds: 1),
    );
    expect(shutdown.outcome, PlaybackShutdownOutcome.released);
    expect(session.currentSnapshot.phase, PlaybackPhase.disposed);
    await subscription.cancel();
  });
}

PlaybackPlan _plan(
  String key, {
  PlaybackSeekPolicy seekPolicy = PlaybackSeekPolicy.allowed,
  PlaybackTimelineKind kind = PlaybackTimelineKind.onDemand,
  List<String>? candidates,
  bool audioOnly = false,
}) => PlaybackPlan(
  contentKey: key,
  source: PlaybackSourceSnapshot.fromDataSource(
    NetworkSource(
      videoSource: candidates?.first ?? 'https://example.test/$key.mp4',
      audioSource: null,
      videoCandidates: candidates ?? const [],
    ),
  ),
  timeline: PlaybackTimeline(
    kind: kind,
    seekPolicy: seekPolicy,
    duration: kind == PlaybackTimelineKind.live
        ? null
        : const Duration(seconds: 10),
  ),
  configuration: PlaybackConfiguration(audioOnly: audioOnly),
);

PlaybackRuntimeLoadResult _failedLoad(PlaybackExecutionContext context) =>
    PlaybackRuntimeLoadResult(
      loaded: false,
      output: PlaybackOutputPreparation(
        strategy: PlaybackOutputStrategy.failed,
        evidence: 'source-failed',
        outputEpoch: context.loadId,
      ),
    );

PlaybackRuntimeLoadResult _audioLoaded(PlaybackExecutionContext context) =>
    PlaybackRuntimeLoadResult(
      loaded: true,
      output: PlaybackOutputPreparation(
        strategy: PlaybackOutputStrategy.noVideo,
        evidence: 'native-track-list-no-video',
        outputEpoch: context.loadId,
        hasVideo: false,
      ),
      capabilities: const PlaybackCapabilities(hasVideo: false, hasAudio: true),
    );

PlaybackRuntimeLoadResult _loaded(
  PlaybackExecutionContext context,
  PlaybackPlan plan,
) => PlaybackRuntimeLoadResult(
  loaded: true,
  output: PlaybackOutputPreparation(
    strategy: PlaybackOutputStrategy.prepared,
    evidence: 'fake-explicit-ack',
    outputEpoch: context.loadId,
    hasVideo: true,
  ),
  capabilities: PlaybackCapabilities(
    seekSupport: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? PlaybackSeekSupport.supported
        : PlaybackSeekSupport.unknown,
    seekStart: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? Duration.zero
        : null,
    seekEnd: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? plan.timeline.duration
        : null,
    hasVideo: true,
    hasAudio: false,
  ),
);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not become true.');
}

class _FakeRuntime implements PlaybackRuntimePort {
  @override
  final int runtimeId = 51;
  @override
  Duration? position;
  @override
  bool shaderChangeRequiresRendererReset = false;
  final StreamController<PlaybackRuntimeEvent> _events =
      StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final Completer<void> _released = Completer<void>();
  final loadedKeys = <String>[];
  final loadedPlans = <PlaybackPlan>[];
  final playCalls = <bool>[];
  final seekCalls = <Duration>[];
  final audioReloadContexts = <PlaybackExecutionContext>[];
  Future<PlaybackRuntimeCommandResult> Function(PlaybackExecutionContext)?
  onReloadAudio;
  final shaderCalls = <List<String>>[];
  final decoderCalls = <String>[];
  final audioOnlyCalls = <bool>[];
  final speedCalls = <({double speed, Map<String, String> mediaOptions})>[];
  int _loadIndex = 0;
  int _playIndex = 0;
  Future<PlaybackShutdownResult> Function()? onShutdown;
  Future<PlaybackRuntimeLoadResult> Function(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
    int index,
  )?
  onLoad;
  Future<PlaybackRuntimeCommandResult> Function(
    bool playing,
    PlaybackExecutionContext context,
    int index,
  )?
  onSetPlaying;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  void emitActual(int loadId, PlaybackActual actual) {
    position = actual.position;
    _events.add(
      PlaybackRuntimeStateChanged(
        runtimeId: runtimeId,
        loadId: loadId,
        actual: actual,
      ),
    );
  }

  void completeRelease() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    final index = _loadIndex++;
    loadedKeys.add(plan.contentKey);
    loadedPlans.add(plan);
    final result = onLoad == null
        ? _loaded(context, plan)
        : await onLoad!(plan, context, index);
    return result;
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) {
    // 与原生运行时一致：失去归属的命令不会触碰播放器。
    if (!context.isCurrent()) {
      return Future.value(
        const PlaybackRuntimeCommandResult(applied: false),
      );
    }
    final index = _playIndex++;
    if (onSetPlaying != null) return onSetPlaying!(playing, context, index);
    playCalls.add(playing);
    return Future.value(const PlaybackRuntimeCommandResult());
  }

  @override
  Future<PlaybackRuntimeCommandResult> seek(
    Duration target,
    PlaybackExecutionContext context,
  ) async {
    seekCalls.add(target);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaybackSpeed(
    double value,
    Map<String, String> mediaOptions,
    PlaybackExecutionContext context,
  ) async {
    speedCalls.add((speed: value, mediaOptions: Map.of(mediaOptions)));
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  ) async {
    audioOnlyCalls.add(value);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setAudioTrack(
    int? trackId,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> reloadAudio(
    PlaybackExecutionContext context,
  ) async {
    audioReloadContexts.add(context);
    return onReloadAudio == null
        ? const PlaybackRuntimeCommandResult()
        : onReloadAudio!(context);
  }

  @override
  Future<PlaybackRuntimeCommandResult> setSubtitleTrack(
    PlaybackSubtitleTrack? track,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setDecoder(
    PlaybackDecoder decoder,
    PlaybackExecutionContext context,
  ) async {
    decoderCalls.add(decoder.value);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  ) async {
    shaderCalls.add(List.of(shaders));
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    final handler = onShutdown;
    if (handler != null) return handler();
    completeRelease();
    unawaited(_events.close());
    return const PlaybackShutdownResult.released();
  }
}

class _GatedRuntime extends _FakeRuntime implements PlaybackSeekSubmissionGate {
  final changes = StreamController<void>.broadcast(sync: true);
  bool blocked = true;
  void unblock() {
    blocked = false;
    changes.add(null);
  }

  @override
  bool get seekSubmissionBlocked => blocked;
  @override
  Stream<void> get seekSubmissionChanges => changes.stream;
}

class _SamplingRuntime extends _FakeRuntime
    implements PlaybackMediaClockSampler {
  void Function()? onSample;
  @override
  void sampleMediaClock() => onSample?.call();
}
