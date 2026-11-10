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
  final _independent = <IndependentAudioLease>[];
  Future<void> _focusChanges = Future<void>.value();
  bool _interrupted = false;
  bool _ducked = false;
  PlPlayerController? _playbackController;

  IndependentAudioLease acquireIndependentPlayer({
    required Future<void> Function(bool) setPlaying,
    required double Function() volume,
    required int Function() volumeRevision,
    required Future<void> Function(double) setVolume,
  }) {
    final previous = _independent.lastOrNull;
    final lease = IndependentAudioLease._(
      this,
      setPlaying,
      volume,
      volumeRevision,
      setVolume,
    );
    _independent.add(lease);
    lease._interrupted = _interrupted;
    final controller = _playbackController ?? PlPlayerController.instance;
    if (controller != null) lease._holdVideo(controller);
    lease._handover = previous?._suspend() ?? Future<void>.value();
    lease._consume(lease._handover);
    return lease;
  }

  Future<T> _serializeFocus<T>(Future<T> Function() operation) {
    final result = _focusChanges.then((_) => operation());
    _focusChanges = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<bool> changeVideoActive(
    PlPlayerController controller,
    bool active, {
    bool Function()? isCurrent,
  }) {
    _playbackController ??= controller;
    return _serializeFocus(() async {
      if (_independent.isNotEmpty ||
          !identical(controller, _playbackController) ||
          isCurrent?.call() == false) {
        return true;
      }
      return setActive(active);
    });
  }

  Future<bool> _changeIndependentActive(
    IndependentAudioLease lease,
    bool active,
  ) => _serializeFocus(() async {
    if (!identical(_independent.lastOrNull, lease)) return false;
    if (active && (lease._closing || !lease._playing || lease._interrupted)) {
      return true;
    }
    if (!active && !lease._closing && lease._playing && !lease._interrupted) {
      return true;
    }
    return setActive(active);
  });
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
      if (event.type == AudioInterruptionType.duck) _ducked = event.begin;
      if (event.type != AudioInterruptionType.duck) _interrupted = event.begin;
      final independent = _independent.lastOrNull;
      if (independent != null) {
        independent._handleInterruption(event);
        // 视频即使被独立播放器遮挡，也需保留系统中断状态以供交还。
        if (event.type == AudioInterruptionType.duck) {
          // 接管前的视频 duck 快照仍需在系统事件结束时恢复。
          if (!event.begin) unawaited(_ducker.end());
          return;
        }
      }
      final controller = _playbackController ?? PlPlayerController.instance;
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
      final independent = _independent.lastOrNull;
      if (independent != null) {
        independent._consume(independent.setPlaying(false));
        return;
      }
      final owner = (_playbackController ?? PlPlayerController.instance)
          ?.activePlaybackOwner;
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
    _playbackController = controller;
    for (final lease in _independent) {
      lease._holdVideo(controller);
    }
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

/// 独立音频持有视频抑制直到真实释放；中断只改变有效播放，不改用户意图。
class IndependentAudioLease {
  IndependentAudioLease._(
    this._handler,
    this._setPlaying,
    this._volume,
    this._volumeRevision,
    this._setVolume,
  );

  final AudioSessionHandler _handler;
  final Future<void> Function(bool) _setPlaying;
  final double Function() _volume;
  final int Function() _volumeRevision;
  final Future<void> Function(double) _setVolume;
  final _videoHolds = <PlPlayerController, PlaybackInhibitorToken?>{};
  final _ducker = PlaybackVolumeDucker(onError: Utils.reportError);
  Future<void> _commands = Future<void>.value();
  Future<void> _handover = Future<void>.value();
  Future<void>? _closingOperation;
  Future<void>? _duckChange;
  bool _playing = false;
  bool _interrupted = false;
  bool _closing = false;
  int _videoHoldRevision = 0;
  int _intentRevision = 0;
  int get intentRevision => _intentRevision;
  bool get playingIntent => _playing;
  bool get _current => identical(_handler._independent.lastOrNull, this);

  void _holdVideo(PlPlayerController controller) {
    if (_videoHolds.containsKey(controller)) return;
    final token = controller.acquireSessionInhibitor(
      PlaybackInhibitorSource.audioFocus,
    );
    // closing session 不再发放令牌，但原生释放屏障仍属于此次接管。
    _videoHolds[controller] = token;
    _videoHoldRevision++;
  }

  Future<void> _enqueue(Future<void> Function() command) {
    final result = _commands.then((_) => command());
    _commands = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> prepare() async {
    await _handover;
    int revision;
    do {
      revision = _videoHoldRevision;
      for (final controller in _videoHolds.keys.toList()) {
        final result = await controller.synchronizePlaybackIntent();
        if (result.outcome == CommandOutcome.failed) {
          throw result.failure ?? StateError('视频暂停未确认');
        }
      }
    } while (revision != _videoHoldRevision);
  }

  Future<void> setPlaying(bool playing) {
    if (_closing) return Future.error(StateError('音频播放器已关闭'));
    _playing = playing;
    _intentRevision++;
    return _enqueue(_reconcile);
  }

  Future<void> _reconcile() async {
    if (_closing || !_current) return;
    await prepare();
    if (_closing || !_current) return;
    final effective = _playing && !_interrupted;
    if (effective) {
      if (!await _handler._changeIndependentActive(this, true)) {
        throw StateError('系统未授予音频焦点');
      }
      if (_closing || !_current) return;
      await prepare();
      if (_closing || !_current) return;
      // 焦点申请的 await 期间也可能收到暂停或中断。
      await _setPlaying(_playing && !_interrupted);
      if (_handler._ducked) _applyDuck();
    } else {
      await _setPlaying(false);
      if (!_interrupted && _current) {
        await _handler._changeIndependentActive(this, false);
      }
    }
  }

  Future<void> _suspend() =>
      _closingOperation ??
      _enqueue(() async {
        await _handover;
        await _duckChange;
        await _ducker.end();
        await _setPlaying(false);
      });

  void _consume(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stack) {
        Utils.reportError(error, stack);
      }),
    );
  }

  void _handleInterruption(AudioInterruptionEvent event) {
    if (_closing) return;
    if (event.type != AudioInterruptionType.duck) {
      _interrupted = event.begin;
      _consume(_enqueue(_reconcile));
      return;
    }
    if (!event.begin) {
      _consume(_ducker.end());
    } else if (_playing && _current) {
      _applyDuck();
    }
  }

  void _applyDuck() {
    final operation = _ducker.begin(
      owner: this,
      volume: _volume(),
      currentVolume: _volume,
      currentRevision: _volumeRevision,
      isCurrent: () => !_closing,
      setVolume: (value) async {
        await _setVolume(value);
        return const CommandResult.applied();
      },
    );
    _duckChange = operation;
    _consume(operation);
  }

  /// release 失败时保留抑制，防止仍可能发声的 Player 与视频同时输出。
  Future<void> close(Future<void> Function() release) =>
      _closingOperation ??= _close(release);

  Future<void> _close(Future<void> Function() release) async {
    _closing = true;
    await _commands;
    for (final operation in [_handover, _duckChange]) {
      try {
        await operation;
      } catch (error, stack) {
        // 辅助命令失败仍需销毁 Player，真实销毁结果才决定能否交还声音。
        Utils.reportError(error, stack);
      }
    }
    await release();
    final wasCurrent = _current;
    if (wasCurrent) {
      try {
        await _handler._changeIndependentActive(this, false);
      } catch (error, stack) {
        // Player 已确认销毁，焦点释放失败不能阻止后续播放器重新申请。
        Utils.reportError(error, stack);
      }
    }
    _handler._independent.remove(this);
    // 最后一个独立播放器交还前先恢复视频的系统焦点，避免旧释放晚于新申请。
    if (_handler._independent.isEmpty) {
      final controller =
          _handler._playbackController ?? PlPlayerController.instance;
      if (controller != null &&
          controller.activePlaybackOwner?.isActive == true &&
          controller.currentPlaybackSnapshot.intent.playing) {
        try {
          await _handler.changeVideoActive(controller, true);
        } catch (error, stack) {
          Utils.reportError(error, stack);
        }
      }
    }
    for (final entry in _videoHolds.entries.toList()) {
      final token = entry.value;
      if (token != null) await entry.key.releaseSessionInhibitor(token);
    }
    _videoHolds.clear();
    final previous = _handler._independent.lastOrNull;
    if (wasCurrent && previous != null) {
      previous._interrupted = _handler._interrupted;
      await previous._enqueue(previous._reconcile);
    }
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
