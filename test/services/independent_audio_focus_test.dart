import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/audio_session.dart';

class _Session implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast(
    sync: true,
  );
  final noisy = StreamController<void>.broadcast(sync: true);
  final activations = <bool>[];
  bool allowed = true;
  Completer<void>? activation;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
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
    await activation?.future;
    return allowed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player {
  final playing = <bool>[];
  double volume = 80;
  int revision = 0;
  Completer<void>? pause;
  IndependentAudioLease acquire(AudioSessionHandler handler) =>
      handler.acquireIndependentPlayer(
        setPlaying: (value) async {
          if (!value) await pause?.future;
          playing.add(value);
        },
        volume: () => volume,
        volumeRevision: () => revision,
        setVolume: (value) async {
          revision++;
          volume = value;
        },
      );
}

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  late _Session session;
  late AudioSessionHandler handler;
  setUp(() async {
    session = _Session();
    handler = AudioSessionHandler(loadSession: () async => session);
    await handler.initSession();
  });
  tearDown(() async {
    await session.interruptions.close();
    await session.noisy.close();
  });
  test(
    'focus refusal preserves cause boundary and allows same play retry',
    () async {
      final player = _Player();
      final lease = player.acquire(handler);
      session.allowed = false;
      await expectLater(lease.setPlaying(true), throwsStateError);
      expect(player.playing, isEmpty);
      session.allowed = true;
      await lease.setPlaying(true);
      expect(player.playing, [true]);
      await lease.close(() async {});
    },
  );
  test(
    'interruption preserves intent and explicit pause prevents resume',
    () async {
      final player = _Player();
      final lease = player.acquire(handler);
      await lease.setPlaying(true);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await _drain();
      expect(player.playing.last, false);
      expect(lease.playingIntent, true);
      await lease.setPlaying(false);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await _drain();
      expect(player.playing.last, false);
      expect(lease.playingIntent, false);
      await lease.close(() async {});
    },
  );
  test(
    'noisy event pauses current audio and never resumes on interruption end',
    () async {
      final player = _Player();
      final lease = player.acquire(handler);
      await lease.setPlaying(true);
      session.noisy.add(null);
      await _drain();
      expect(player.playing.last, false);
      expect(lease.playingIntent, false);
      await lease.close(() async {});
    },
  );
  test('duck restores once and preserves newer user volume', () async {
    final player = _Player();
    final lease = player.acquire(handler);
    await lease.setPlaying(true);
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await _drain();
    expect(player.volume, 40);
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await _drain();
    expect(player.volume, 80);
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await _drain();
    player.volume = 63;
    player.revision++;
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    await _drain();
    expect(player.volume, 63);
    await lease.close(() async {});
  });
  test('takeover waits for previous pause and old close does not release new focus', () async {
    final first = _Player();
    final firstLease = first.acquire(handler);
    await firstLease.setPlaying(true);
    first.pause = Completer<void>();
    final second = _Player();
    final secondLease = second.acquire(handler);
    final play = secondLease.setPlaying(true);
    await _drain();
    expect(second.playing, isEmpty);
    first.pause!.complete();
    await play;
    session.activations.clear();
    await firstLease.close(() async {});
    expect(session.activations, isEmpty);
    expect(second.playing, [true]);
    await secondLease.close(() async {});
  });
  test('close waits for actual release before focus release and restoring previous audio', () async {
    final first = _Player();
    final firstLease = first.acquire(handler);
    await firstLease.setPlaying(true);
    final second = _Player();
    final secondLease = second.acquire(handler);
    await secondLease.setPlaying(true);
    session.activations.clear();
    final released = Completer<void>();
    final close = secondLease.close(() => released.future);
    await _drain();
    expect(session.activations, isEmpty);
    expect(first.playing, [true, false]);
    released.complete();
    await close;
    expect(session.activations, [false, true]);
    expect(first.playing.last, true);
    await firstLease.close(() async {});
  });
  test(
    'new audio waits when previous destruction is already pending',
    () async {
      final first = _Player().acquire(handler);
      await first.setPlaying(true);
      final released = Completer<void>();
      final close = first.close(() => released.future);
      await _drain();
      final second = _Player();
      final lease = second.acquire(handler);
      final playing = lease.setPlaying(true);
      await _drain();
      expect(second.playing, isEmpty);
      released.complete();
      await close;
      await playing;
      expect(second.playing, [true]);
      await lease.close(() async {});
    },
  );
  test('pause during focus request prevents late native play', () async {
    final player = _Player();
    final lease = player.acquire(handler);
    session.activation = Completer<void>();
    final play = lease.setPlaying(true);
    await _drain();
    final pause = lease.setPlaying(false);
    session.activation!.complete();
    await play;
    await pause;
    expect(player.playing, everyElement(false));
    await lease.close(() async {});
  });

  test('handover failure still destroys the new player on close', () async {
    var released = false;
    final first = handler.acquireIndependentPlayer(
      setPlaying: (playing) async {
        if (!playing) throw StateError('synthetic pause failure');
      },
      volume: () => 80,
      volumeRevision: () => 0,
      setVolume: (_) async {},
    );
    await first.setPlaying(true);
    final second = _Player().acquire(handler);
    await expectLater(second.prepare(), throwsStateError);
    await second.close(() async => released = true);
    expect(released, isTrue);
    await first.close(() async {});
  });
}
