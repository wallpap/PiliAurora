import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/utils/utils.dart';

class AudioSessionHandler {
  AudioSessionHandler({Future<AudioSession> Function()? loadSession})
    : _loadSession = loadSession ?? (() => AudioSession.instance);

  final Future<AudioSession> Function() _loadSession;
  Future<void>? _initialization;
  late AudioSession session;
  final PlaybackFocusInhibitor _focusInhibitor = PlaybackFocusInhibitor(
    onError: Utils.reportError,
  );
  final PlaybackVolumeDucker _ducker = PlaybackVolumeDucker(
    onError: Utils.reportError,
  );

  Future<bool> setActive(bool active) async {
    await initSession();
    return session.setActive(active);
  }

  /// 启动和首次激活共用初始化 Future，配置失败后允许再次尝试。
  Future<void> initSession() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _configureSession();
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _configureSession() async {
    session = await _loadSession();
    await session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      final controller = PlPlayerController.instance;
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            final owner = controller?.activePlaybackOwner;
            if (controller != null &&
                owner != null &&
                controller.currentPlaybackSnapshot.intent.playing) {
              unawaited(_duck(controller, owner));
            }
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            _focusInhibitor.begin();
            if (controller != null) attachPlaybackController(controller);
            break;
        }
        return;
      }

      switch (event.type) {
        case AudioInterruptionType.duck:
          unawaited(_ducker.end());
          break;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          unawaited(_focusInhibitor.end());
          break;
      }
    });

    // 拔出耳机是显式用户暂停，需更新播放意图。
    session.becomingNoisyEventStream.listen((_) async {
      final owner = PlPlayerController.instance?.activePlaybackOwner;
      if (owner == null) return;
      try {
        await owner.setPlaying(false);
      } catch (error, stackTrace) {
        Utils.reportError(error, stackTrace);
      }
    });
  }

  /// 新 facade 在焦点中断期间创建时，立即把系统抑制迁移到新 session。
  void attachPlaybackController(PlPlayerController controller) {
    _focusInhibitor.attach(
      controller,
      acquire: () => controller.acquireSessionInhibitor(
        PlaybackInhibitorSource.audioFocus,
      ),
      release: controller.releaseSessionInhibitor,
    );
  }

  Future<void> _duck(
    PlPlayerController controller,
    PlaybackOwner owner,
  ) async {
    if (!owner.isActive) return;
    final configuration = controller.currentPlaybackSnapshot.configuration;
    await _ducker.begin(
      owner: owner,
      volume: configuration.desired.volume,
      currentVolume: () =>
          controller.currentPlaybackSnapshot.configuration.desired.volume,
      currentRevision: () => controller
          .currentPlaybackSnapshot
          .configuration
          .revisions[PlaybackConfigurationKey.volume],
      isCurrent: () =>
          owner.isActive && identical(controller.activePlaybackOwner, owner),
      setVolume: owner.setVolume,
    );
  }
}

typedef PlaybackFocusAcquire = PlaybackInhibitorToken? Function();
typedef PlaybackFocusRelease = Future<CommandResult> Function(
  PlaybackInhibitorToken token,
);

/// 保留系统失焦状态，并在播放器 facade 换代时迁移 session token。
class PlaybackFocusInhibitor {
  PlaybackFocusInhibitor({this._onError});

  final void Function(Object error, StackTrace stackTrace)? _onError;
  bool _interrupted = false;
  _FocusSessionLease? _lease;

  void begin() => _interrupted = true;

  void attach(
    Object facade, {
    required PlaybackFocusAcquire acquire,
    required PlaybackFocusRelease release,
  }) {
    if (!_interrupted || identical(_lease?.facade, facade)) return;
    final previous = _lease;
    _lease = null;
    if (previous != null) unawaited(_release(previous));
    final token = acquire();
    if (token != null) {
      _lease = _FocusSessionLease(
        facade: facade,
        token: token,
        release: release,
      );
    }
  }

  Future<void> end() async {
    _interrupted = false;
    final lease = _lease;
    _lease = null;
    if (lease != null) await _release(lease);
  }

  Future<void> _release(_FocusSessionLease lease) async {
    try {
      await lease.release(lease.token);
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
  }
}

class _FocusSessionLease {
  const _FocusSessionLease({
    required this.facade,
    required this.token,
    required this.release,
  });

  final Object facade;
  final PlaybackInhibitorToken token;
  final PlaybackFocusRelease release;
}

typedef PlaybackDuckingVolumeCommand = Future<CommandResult> Function(
  double volume,
);

/// 管理音频焦点 duck 的音量快照与恢复，重复事件不重复减半。
class PlaybackVolumeDucker {
  PlaybackVolumeDucker({this._onError});

  final void Function(Object error, StackTrace stackTrace)? _onError;
  _DuckingState? _state;
  int _generation = 0;

  Future<void> begin({
    required Object owner,
    required double volume,
    required double Function() currentVolume,
    required int? Function() currentRevision,
    required bool Function() isCurrent,
    required PlaybackDuckingVolumeCommand setVolume,
  }) async {
    if (!isCurrent()) return;
    final existing = _state;
    if (existing != null) {
      if (identical(existing.owner, owner) && !existing.restoreRequested) {
        return;
      }
      if (!existing.restoreRequested) {
        existing
          ..restoreRequested = true
          ..generation = ++_generation;
        if (existing.applyFinished) unawaited(_restore(existing));
      }
      await existing.settled.future;
      if (isCurrent()) {
        await begin(
          owner: owner,
          volume: volume,
          currentVolume: currentVolume,
          currentRevision: currentRevision,
          isCurrent: isCurrent,
          setVolume: setVolume,
        );
      }
      return;
    }

    final state = _DuckingState(
      generation: ++_generation,
      owner: owner,
      before: volume,
      ducked: volume * 0.5,
      currentVolume: currentVolume,
      currentRevision: currentRevision,
      isCurrent: isCurrent,
      setVolume: setVolume,
    );
    // 先登记，再派发命令；end 可以在命令完成前到达。
    _state = state;
    try {
      final command = setVolume(state.ducked);
      state.revision = currentRevision();
      final result = await command;
      if (result.outcome != CommandOutcome.applied &&
          result.outcome != CommandOutcome.accepted) {
        state
          ..restoreRequested = true
          ..generation = ++_generation;
      }
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
      state
        ..restoreRequested = true
        ..generation = ++_generation;
    } finally {
      state.applyFinished = true;
      if (state.restoreRequested) await _restore(state);
    }
  }

  Future<void> end() async {
    final state = _state;
    if (state == null || state.restoreRequested) return;
    state
      ..restoreRequested = true
      ..generation = ++_generation;
    if (state.applyFinished) await _restore(state);
  }

  Future<void> _restore(_DuckingState state) async {
    if (state.restoring) return;
    state.restoring = true;
    try {
      if (state.revision != null &&
          state.isCurrent() &&
          state.currentVolume() == state.ducked &&
          state.currentRevision() == state.revision) {
        try {
          await state.setVolume(state.before);
        } catch (error, stackTrace) {
          _onError?.call(error, stackTrace);
        }
      }
    } finally {
      if (identical(_state, state) && state.generation == _generation) {
        _state = null;
      }
      if (!state.settled.isCompleted) state.settled.complete();
    }
  }
}

class _DuckingState {
  _DuckingState({
    required this.generation,
    required this.owner,
    required this.before,
    required this.ducked,
    required this.currentVolume,
    required this.currentRevision,
    required this.isCurrent,
    required this.setVolume,
  });

  int generation;
  final Object owner;
  final double before;
  final double ducked;
  final double Function() currentVolume;
  final int? Function() currentRevision;
  final bool Function() isCurrent;
  final PlaybackDuckingVolumeCommand setVolume;
  int? revision;
  bool applyFinished = false;
  bool restoreRequested = false;
  bool restoring = false;
  final Completer<void> settled = Completer<void>();
}
