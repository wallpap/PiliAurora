import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_decode_recovery.dart';

void main() {
  late String? active;
  late List<String> applied;
  late List<Object> errors;
  late AndroidDecodeRecovery recovery;

  setUp(() {
    active = 'mediacodec';
    applied = [];
    errors = [];
    recovery = AndroidDecodeRecovery(
      activeDecoder: () => active,
      applyDecoder: (value) {
        applied.add(value);
        active = value;
      },
      onError: errors.add,
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
  });

  testWidgets('decoder update failures are reported without retry loops', (
    tester,
  ) async {
    recovery.dispose();
    recovery = AndroidDecodeRecovery(
      activeDecoder: () => active,
      applyDecoder: (_) => throw StateError('decoder disposed'),
      onError: errors.add,
    );
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(errors, hasLength(1));
  });
}
