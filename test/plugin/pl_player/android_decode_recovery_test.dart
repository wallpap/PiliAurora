import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_decode_recovery.dart';

void main() {
  testWidgets(
    'diagnostics include fallback cause and budgets without changing recovery',
    (tester) async {
      var decoder = 'mediacodec';
      final events = <(String, Map<String, Object?>)>[];
      final recovery =
          AndroidDecodeRecovery(
            activeDecoder: () => decoder,
            applyDecoder: (value) => decoder = value,
            onError: (error) => fail(error.toString()),
            onDiagnostic: (action, details) => events.add((action, details)),
          )..onLog(
            prefix: 'ffmpeg/video',
            level: 'error',
            message: 'mediacodec: Both surface and native_window are null',
          );
      await tester.pump(const Duration(milliseconds: 201));
      expect(decoder, 'mediacodec-copy');
      expect(events.first.$1, 'decoder.recovery.scheduled');
      expect(events.first.$2['reason'], 'mediacodec-null-surface');
      expect(events.last.$2, containsPair('from', 'mediacodec'));
      expect(events.last.$2, containsPair('to', 'mediacodec-copy'));
      recovery
        ..reset()
        ..dispose();
      expect(events.last.$1, 'decoder.recovery.reset');
    },
  );
  testWidgets('a failing diagnostic observer cannot block decoder fallback', (
    tester,
  ) async {
    var decoder = 'mediacodec';
    final recovery =
        AndroidDecodeRecovery(
          activeDecoder: () => decoder,
          applyDecoder: (value) => decoder = value,
          onError: (error) => fail(error.toString()),
          onDiagnostic: (_, _) => throw StateError('observer failed'),
        )..onLog(
          prefix: 'vo/gpu/aimagereader',
          level: 'error',
          message: 'acquireLatestImage failed',
        );
    await tester.pump(const Duration(milliseconds: 201));
    expect(decoder, 'mediacodec-copy');
    recovery.dispose();
  });

  late String? active;
  late List<String> applied;
  late List<Object> errors;
  late List<String> fallbacks;
  late AndroidDecodeRecovery recovery;

  setUp(() {
    active = 'mediacodec';
    applied = [];
    errors = [];
    fallbacks = [];
    recovery = AndroidDecodeRecovery(
      activeDecoder: () => active,
      applyDecoder: (value) {
        applied.add(value);
        active = value;
      },
      onError: errors.add,
      onFallback: fallbacks.add,
    );
  });
  tearDown(() => recovery.dispose());

  void surfaceError([String codec = 'av1']) => recovery.onLog(
    prefix: 'ffmpeg/video',
    level: 'error',
    message: '${codec}_mediacodec: Both surface and native_window are NULL',
  );

  void imageError() => recovery.onLog(
    prefix: 'vo/gpu/aimagereader',
    level: 'error',
    message: 'acquireLatestImage failed: -30001',
  );

  testWidgets('decoder fallback notifies once per media, not once per step', (
    tester,
  ) async {
    imageError();
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(fallbacks, ['mediacodec-copy']);
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy', 'no']);
    expect(fallbacks, ['mediacodec-copy']);
    recovery.reset();
    active = 'mediacodec-copy';
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(fallbacks, ['mediacodec-copy', 'no']);
  });

  testWidgets(
    'persistent AV1 parse errors after software fallback reload once',
    (
      tester,
    ) async {
      recovery.dispose();
      var reloads = 0;
      recovery = AndroidDecodeRecovery(
        activeDecoder: () => active,
        applyDecoder: (value) {
          applied.add(value);
          active = value;
        },
        recoverSoftware: () async {
          reloads++;
          return true;
        },
        onError: errors.add,
      );
      imageError();
      await tester.pump(const Duration(milliseconds: 200));
      surfaceError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(active, 'no');
      for (var i = 0; i < 20; i++) {
        recovery.onLog(
          prefix: 'ffmpeg/video',
          level: 'error',
          message: 'libdav1d: Error parsing OBU data',
        );
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1);
      expect(applied, ['mediacodec-copy', 'no']);
      for (var i = 0; i < 20; i++) {
        recovery.onLog(
          prefix: 'ffmpeg/video',
          level: 'error',
          message: 'libdav1d: Error parsing OBU data',
        );
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1, reason: 'damaged media must not cause a reload loop');
    },
  );

  group('software parse recovery lifecycle', () {
    late int reloads;
    late Future<bool> Function() reload;

    setUp(() {
      recovery.dispose();
      active = 'no';
      reloads = 0;
      reload = () async => true;
      recovery = AndroidDecodeRecovery(
        activeDecoder: () => active,
        applyDecoder: applied.add,
        recoverSoftware: () {
          reloads++;
          return reload();
        },
        onError: errors.add,
      );
    });

    void parseErrors([int count = 3]) {
      for (var i = 0; i < count; i++) {
        recovery.onLog(
          prefix: 'ffmpeg/video',
          level: 'error',
          message: 'libdav1d: Error parsing OBU data',
        );
      }
    }

    testWidgets('isolated damaged frames do not reload', (tester) async {
      parseErrors(2);
      await tester.pump(const Duration(milliseconds: 200));
      parseErrors(2);
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 0);
    });

    testWidgets('hardware probes and warnings do not reload', (tester) async {
      active = 'mediacodec';
      parseErrors(20);
      await tester.pump(const Duration(milliseconds: 200));
      active = 'no';
      recovery.onLog(
        prefix: 'ffmpeg/video',
        level: 'warn',
        message: 'libdav1d: Error parsing OBU data',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 0);
    });

    testWidgets('native recovery before the timer prevents reload', (
      tester,
    ) async {
      parseErrors();
      active = 'mediacodec';
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 0);
    });

    testWidgets('reset cancels pending work and restores one retry', (
      tester,
    ) async {
      parseErrors();
      recovery.reset();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 0);
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1);
      recovery.reset();
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 2);
    });

    testWidgets('disposal cancels a software recovery', (tester) async {
      parseErrors();
      recovery.dispose();
      await tester.pump(const Duration(milliseconds: 200));
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 0);
    });

    testWidgets('busy media load does not consume the recovery budget', (
      tester,
    ) async {
      reload = () async => false;
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1);
      reload = () async => true;
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 2);
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 2);
    });

    testWidgets('failed reload reports once without retrying', (tester) async {
      reload = () => Future<bool>.error(StateError('reload failed'));
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      parseErrors(20);
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1);
      expect(errors, hasLength(1));
    });

    testWidgets('late rejection cannot consume new media recovery', (
      tester,
    ) async {
      final gate = Completer<bool>();
      reload = () => gate.future;
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 1);
      recovery.reset();
      gate.completeError(StateError('old source failed'));
      await tester.pump();
      reload = () async => true;
      parseErrors();
      await tester.pump(const Duration(milliseconds: 200));
      expect(reloads, 2);
      expect(errors, isEmpty);
    });
  });

  testWidgets(
    'AV1 and HEVC errors coalesce and recover through copy then software',
    (tester) async {
      surfaceError();
      surfaceError('hevc');
      imageError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, ['mediacodec-copy']);
      imageError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, ['mediacodec-copy', 'no']);
      active = 'mediacodec';
      imageError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied.length, 2);
      expect(errors, isEmpty);
    },
  );

  testWidgets(
    'profile warnings and isolated timeouts do not interrupt playback',
    (tester) async {
      recovery
        ..onLog(
          prefix: 'ffmpeg/video',
          level: 'warn',
          message: 'av1_mediacodec: Unsupported or unknown profile',
        )
        ..onLog(
          prefix: 'vo/gpu/aimagereader',
          level: 'warn',
          message: 'Waiting for frame timed out!',
        );
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, isEmpty);
      expect(fallbacks, isEmpty);
    },
  );

  testWidgets('native fallback completion makes pending recovery unnecessary', (
    tester,
  ) async {
    surfaceError();
    active = 'no';
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    active = null;
    imageError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    expect(fallbacks, isEmpty);
  });

  testWidgets('new media cancels pending work and restores recovery budget', (
    tester,
  ) async {
    imageError();
    recovery.reset();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    active = 'mediacodec-copy';
    imageError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['no']);
    recovery.reset();
    active = 'mediacodec';
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['no', 'mediacodec-copy']);
  });

  testWidgets(
    'a stuck native decoder cannot repeat copy recovery indefinitely',
    (tester) async {
      surfaceError();
      await tester.pump(const Duration(milliseconds: 200));
      active = 'mediacodec';
      surfaceError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, ['mediacodec-copy', 'no']);
      active = 'mediacodec';
      surfaceError();
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, hasLength(2));
    },
  );

  testWidgets('disposal cancels recovery and rejects later logs', (
    tester,
  ) async {
    imageError();
    recovery.dispose();
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    expect(fallbacks, isEmpty);
  });

  testWidgets('decoder update failures are reported without retry loops', (
    tester,
  ) async {
    recovery.dispose();
    recovery = AndroidDecodeRecovery(
      activeDecoder: () => active,
      applyDecoder: (_) => throw StateError('decoder disposed'),
      onError: errors.add,
      onFallback: fallbacks.add,
    );
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(errors, hasLength(1));
    expect(fallbacks, isEmpty);
  });

  testWidgets('notification failures do not stop the fallback chain', (
    tester,
  ) async {
    recovery.dispose();
    recovery = AndroidDecodeRecovery(
      activeDecoder: () => active,
      applyDecoder: (value) {
        active = value;
        applied.add(value);
      },
      onFallback: (_) => throw StateError('notification failed'),
      onError: errors.add,
    );
    imageError();
    await tester.pump(const Duration(milliseconds: 200));
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy', 'no']);
    expect(errors, hasLength(1));
  });
}
