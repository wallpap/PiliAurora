import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_decode_recovery.dart';

void main() {
  late _Playback playback;
  late AndroidDecodeRecovery recovery;
  late List<String> applied;
  late List<(String, Map<String, Object?>)> events;
  late int reloads;

  setUp(() {
    playback = _Playback();
    applied = [];
    events = [];
    reloads = 0;
    recovery = AndroidDecodeRecovery(
      readState: () => playback.attached ? playback.state : null,
      applyDecoder: (decoder) {
        applied.add(decoder);
        playback.decoder = decoder;
      },
      recoverSoftware: () async {
        reloads++;
        return true;
      },
      onDiagnostic: (action, details) => events.add((action, details)),
      onError: (error) => fail(error.toString()),
    );
  });
  tearDown(() => recovery.dispose());

  void imageError([int code = -30001]) => recovery.onLog(
    prefix: 'vo/gpu/aimagereader',
    level: 'error',
    message: 'acquireLatestImage failed: $code',
  );

  void surfaceError() => recovery.onLog(
    prefix: 'ffmpeg/video',
    level: 'error',
    message: 'hevc_mediacodec: Both surface and native_window are NULL',
  );

  testWidgets('successful HEVC copy output survives its null-surface log', (
    tester,
  ) async {
    imageError(-30002);
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy']);
    surfaceError();
    recovery.onLog(
      prefix: 'vd',
      level: 'info',
      message: 'Using hardware decoding (mediacodec-copy).',
    );
    playback.videoPts = 95.166;
    await tester.pump(const Duration(milliseconds: 500));
    expect(applied, ['mediacodec-copy']);
    expect(events.any((e) => e.$2['reason'] == 'copy-memory-output'), isTrue);
  });

  testWidgets('completed media does not recover from a trailing frame error', (
    tester,
  ) async {
    playback
      ..completed = true
      ..playing = false;
    imageError();
    await tester.pump(const Duration(milliseconds: 600));
    expect(applied, isEmpty);
    expect(events.any((e) => e.$2['reason'] == 'media-finished'), isTrue);
  });

  testWidgets('EOF arriving during recovery cancels the pending switch', (
    tester,
  ) async {
    imageError(-30002);
    playback.eof = true;
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
  });

  testWidgets('one empty ImageReader result does not rebuild the decoder', (
    tester,
  ) async {
    imageError();
    await tester.pump(const Duration(milliseconds: 600));
    expect(applied, isEmpty);
  });

  testWidgets('repeated empty results do not interrupt advancing video', (
    tester,
  ) async {
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    imageError();
    playback.videoPts = 95.033;
    await tester.pump(const Duration(milliseconds: 301));
    expect(applied, isEmpty);
  });

  testWidgets('persistent empty results with stalled video recover once', (
    tester,
  ) async {
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    imageError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    await tester.pump(const Duration(milliseconds: 101));
    expect(applied, ['mediacodec-copy']);
    imageError();
    await tester.pump(const Duration(milliseconds: 600));
    expect(applied, ['mediacodec-copy']);
  });

  for (final waiting in ['seeking', 'buffering', 'paused', 'unknown-pts']) {
    testWidgets('empty frames while $waiting preserve the decoder', (
      tester,
    ) async {
      switch (waiting) {
        case 'seeking':
          playback.seeking = true;
        case 'buffering':
          playback.buffering = true;
        case 'paused':
          playback.playing = false;
        case 'unknown-pts':
          playback.videoPts = null;
      }
      imageError();
      imageError();
      imageError();
      await tester.pump(const Duration(milliseconds: 600));
      expect(applied, isEmpty);
    });
  }

  testWidgets('a genuine copy decoder output failure still falls back', (
    tester,
  ) async {
    playback.decoder = 'mediacodec-copy';
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    recovery.onLog(
      prefix: 'ffmpeg/video',
      level: 'error',
      message: 'hevc_mediacodec: Failed to dequeue output buffer (status=-1)',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['no']);
  });

  testWidgets('paused media can still recover a genuine surface failure', (
    tester,
  ) async {
    playback.playing = false;
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy']);
  });

  testWidgets('native copy recovery prevents a queued direct fallback', (
    tester,
  ) async {
    surfaceError();
    playback
      ..decoder = 'mediacodec-copy'
      ..videoPts = 95.033;
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
  });

  testWidgets('unloading media cancels stalled-video recovery', (
    tester,
  ) async {
    imageError();
    imageError();
    imageError();
    playback.attached = false;
    await tester.pump(const Duration(milliseconds: 600));
    expect(applied, isEmpty);
  });

  testWidgets('EOF suppresses software reload as well as hardware fallback', (
    tester,
  ) async {
    playback.decoder = 'no';
    for (var i = 0; i < 3; i++) {
      recovery.onLog(
        prefix: 'ffmpeg/video',
        level: 'error',
        message: 'libdav1d: Error parsing OBU data',
      );
    }
    playback.eof = true;
    await tester.pump(const Duration(milliseconds: 200));
    expect(reloads, 0);
  });

  testWidgets('a genuine failure replaces a transient frame probe', (
    tester,
  ) async {
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    recovery.onLog(
      prefix: 'ffmpeg/video',
      level: 'error',
      message: 'hevc_mediacodec: Failed to dequeue output buffer (status=-1)',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy']);
  });

  testWidgets('waiting for data interrupts an existing stalled-video probe', (
    tester,
  ) async {
    imageError();
    imageError();
    imageError();
    await tester.pump(const Duration(milliseconds: 100));
    playback.buffering = true;
    imageError();
    playback.buffering = false;
    await tester.pump(const Duration(milliseconds: 401));
    expect(applied, isEmpty);
  });

  testWidgets('native backend changes resolve a queued decoder failure', (
    tester,
  ) async {
    recovery.onLog(
      prefix: 'ffmpeg/video',
      level: 'error',
      message: 'hevc_mediacodec: Failed to dequeue output buffer (status=-1)',
    );
    playback.decoder = 'mediacodec-copy';
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
  });
  for (final unknown in [false, true]) {
    testWidgets(
      'sustained empty images recover with ${unknown ? "unknown" : "advancing"} PTS',
      (tester) async {
        recovery.dispose();
        var now = 0;
        recovery = AndroidDecodeRecovery(
          readState: () => playback.state,
          elapsedMilliseconds: () => now,
          applyDecoder: applied.add,
          onError: (error) => fail(error.toString()),
        );
        for (var i = 0; i < 20; i++) {
          playback.videoPts = unknown ? null : i.toDouble();
          imageError();
          now += 100;
          await tester.pump(const Duration(milliseconds: 100));
          if (i < 19) expect(applied, isEmpty);
        }
        expect(applied, ['mediacodec-copy']);
      },
    );
  }

  testWidgets('HardwareBuffer mapping failures reach recovery', (tester) async {
    recovery.onLog(
      prefix: 'vo/gpu/aimagereader',
      level: 'error',
      message: 'getHardwareBuffer failed: -10000',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy']);
  });

  testWidgets('a rejected copy request preserves copy and software budgets', (
    tester,
  ) async {
    recovery.dispose();
    var attempts = 0;
    final errors = <Object>[];
    recovery = AndroidDecodeRecovery(
      readState: () => playback.state,
      applyDecoder: (decoder) {
        if (++attempts == 1) throw StateError('native rejected request');
        applied.add(decoder);
        playback.decoder = decoder;
      },
      onError: errors.add,
    );
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, isEmpty);
    surfaceError();
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy']);
    recovery.onLog(
      prefix: 'ffmpeg/video',
      level: 'error',
      message: 'hevc_mediacodec: Failed to dequeue output buffer',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(applied, ['mediacodec-copy', 'no']);
    expect(errors, hasLength(1));
  });
}

class _Playback {
  bool attached = true;
  String? decoder = 'mediacodec';
  bool playing = true;
  bool buffering = false;
  bool seeking = false;
  bool completed = false;
  bool eof = false;
  double? videoPts = 95;

  AndroidDecodeState get state => (
    decoder: decoder,
    playing: playing,
    buffering: buffering,
    seeking: seeking,
    completed: completed,
    eof: eof,
    videoPts: videoPts,
  );
}
