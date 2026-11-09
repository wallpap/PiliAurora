import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/audio_session.dart';

class _AudioSession implements AudioSession {
  Future<void> Function()? configureSession;
  int configurations = 0;
  int interruptionSubscriptions = 0;
  int noisySubscriptions = 0;
  final activations = <bool>[];

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    await configureSession?.call();
  }

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream {
    interruptionSubscriptions++;
    return const Stream.empty();
  }

  @override
  Stream<void> get becomingNoisyEventStream {
    noisySubscriptions++;
    return const Stream.empty();
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    return active;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('构造不启动后台初始化，激活等待同一配置且事件只订阅一次', () async {
    final configured = Completer<void>();
    final session = _AudioSession()..configureSession = () => configured.future;
    var loads = 0;
    final handler = AudioSessionHandler(
      loadSession: () async {
        loads++;
        return session;
      },
    );
    expect(loads, 0);
    final initialized = handler.initSession();
    expect(handler.initSession(), same(initialized));
    final activated = handler.setActive(true);
    await Future<void>.delayed(Duration.zero);
    expect(session.activations, isEmpty);
    expect(session.interruptionSubscriptions, 0);
    configured.complete();
    await initialized;
    expect(await activated, isTrue);
    expect(await handler.setActive(false), isFalse);
    expect(loads, 1);
    expect(session.configurations, 1);
    expect(session.activations, [true, false]);
    expect(session.interruptionSubscriptions, 1);
    expect(session.noisySubscriptions, 1);
  });

  test('会话配置失败沿初始化 Future 返回，保留原因与堆栈并允许重试', () async {
    final cause = StateError('synthetic session configuration failure');
    final stack = StackTrace.fromString('#0 audio.configure');
    final session = _AudioSession()
      ..configureSession = () async => Error.throwWithStackTrace(cause, stack);
    final handler = AudioSessionHandler(loadSession: () async => session);
    try {
      await handler.initSession();
      fail('configuration should fail');
    } catch (error, trace) {
      expect(error, same(cause));
      expect(trace.toString(), stack.toString());
    }
    expect(session.interruptionSubscriptions, 0);
    expect(session.activations, isEmpty);
    session.configureSession = null;
    expect(await handler.setActive(true), isTrue);
    expect(session.configurations, 2);
    expect(session.interruptionSubscriptions, 1);
    expect(session.noisySubscriptions, 1);
  });
}
