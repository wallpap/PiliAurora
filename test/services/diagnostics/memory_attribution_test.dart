import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/memory_attribution.dart';

Map<String, Object?> sample(
  int tick, {
  int privateBytes = 100,
  bool player = false,
  bool? fullscreen,
}) => {
  'elapsedMs': tick,
  'time': DateTime.utc(
    2026,
    11,
    12,
  ).add(Duration(milliseconds: tick)).toIso8601String(),
  'route': player ? '/videoV' : '/',
  'process': {'privateBytes': privateBytes},
  'images': {'cacheBytes': 20, 'cacheEntries': 1},
  'sources': {
    if (player)
      'player.1': {
        'session': {'runtimeId': 7},
      },
    if (player && fullscreen != null)
      'videoViewport.1.2': {'player': 'player.1', 'fullScreen': fullscreen},
  },
};

void main() {
  test('periodic snapshots reuse existing samples at five second cadence', () {
    final tracker = MemoryAttribution();
    expect(
      tracker.observe(sample(0)).where((row) => row['kind'] == 'snapshot'),
      hasLength(1),
    );
    for (var tick = 250; tick < 5000; tick += 250) {
      expect(tracker.observe(sample(tick)), isEmpty);
    }
    expect(
      tracker.observe(sample(5000)).where((row) => row['kind'] == 'snapshot'),
      hasLength(1),
    );
  });

  test(
    'playback stages compare process snapshots and mark intervening playback',
    () {
      final tracker = MemoryAttribution()..observe(sample(0));
      final entered = tracker.observe(
        sample(1000, player: true, privateBytes: 200),
      );
      expect(entered.any((row) => row['stage'] == 'playback.observed'), isTrue);
      final fullscreen = tracker.observe(
        sample(2000, player: true, fullscreen: true, privateBytes: 300),
      );
      expect(
        fullscreen.any((row) => row['stage'] == 'fullscreen.entered'),
        isTrue,
      );
      final closed = tracker.observe(sample(3000, privateBytes: 180));
      final event = closed.firstWhere(
        (row) => row['stage'] == 'playback.closed',
      );
      expect(event['privateDeltaBytes'], 80);
      expect(event['peakPrivateBytes'], 300);
      tracker.observe(sample(4000, player: true));
      final delayed = tracker.observe(sample(33000, privateBytes: 170));
      final after = delayed.firstWhere(
        (row) => row['stage'] == 'afterClose.30s',
      );
      expect(after['privateDeltaBytes'], 70);
      expect(after['interveningPlayback'], isTrue);
    },
  );

  test('starting during playback leaves baseline unknown', () {
    final tracker = MemoryAttribution()..observe(sample(0, player: true));
    final closed = tracker.observe(sample(1000));
    final event = closed.firstWhere((row) => row['stage'] == 'playback.closed');
    expect(event['privateDeltaBytes'], isNull);
    expect(event['baseline'], isNull);
  });

  test('final snapshot preserves peaks between ownership summaries', () {
    final tracker = MemoryAttribution()
      ..observe(sample(0))
      ..observe(sample(250, privateBytes: 900));
    final finalRows = tracker.observe(sample(500), force: true);
    final snapshot = finalRows.single;
    expect(snapshot['sessionPeakPrivateBytes'], 900);
    expect((snapshot['process'] as Map)['privateBytes'], 100);
  });

  test(
    'unsupported and stale native observations are never reported as zero',
    () {
      final tracker = MemoryAttribution();
      final rows = tracker.observe({
        ...sample(0),
        'nativeMemory': {'status': 'unavailable'},
        'graphicsMemory': {'status': 'unsupported'},
      });
      final snapshot = rows.firstWhere((row) => row['kind'] == 'snapshot');
      final owners = snapshot['owners'] as Map;
      expect((owners['plugin.video'] as Map)['status'], 'unavailable');
      expect((owners['plugin.video'] as Map)['resources'], isNull);
      expect((owners['engine.raster'] as Map)['status'], 'unsupported');
      expect((snapshot['process'] as Map)['wcBytes'], isNull);
    },
  );

  test(
    'runtime replacement and fullscreen exit are observed independently',
    () {
      final tracker = MemoryAttribution()
        ..observe(sample(0))
        ..observe(sample(1000, player: true, fullscreen: true));
      final exit = tracker.observe(
        sample(2000, player: true, fullscreen: false),
      );
      expect(exit.any((row) => row['stage'] == 'fullscreen.exited'), isTrue);
      final replacement = sample(3000, player: true);
      replacement['sources'] = {
        'player.1': {
          'session': {'runtimeId': 8},
        },
      };
      final changed = tracker.observe(replacement);
      expect(
        changed.where((row) => row['stage'] == 'playback.closed'),
        hasLength(1),
      );
      expect(
        changed.where((row) => row['stage'] == 'playback.observed'),
        hasLength(1),
      );
    },
  );

  test(
    'pending follow ups remain bounded under rapid playback replacement',
    () {
      final tracker = MemoryAttribution()..observe(sample(0));
      for (var index = 1; index <= 100; index++) {
        tracker
          ..observe(sample(index * 2, player: true))
          ..observe(sample(index * 2 + 1));
      }
      final snapshot = tracker
          .observe(sample(10000))
          .firstWhere((row) => row['kind'] == 'snapshot');
      expect(snapshot['pendingFollowUps'], lessThanOrEqualTo(8));
      expect(snapshot['omittedFollowUps'], greaterThan(0));
    },
  );

  test(
    'summary separates process and session identities and bounds stage history',
    () {
      final report = MemoryAttributionReport();
      for (var index = 0; index < 100; index++) {
        report.add({
          'type': 'memoryAttribution',
          'runId': 'run',
          'processId': 1,
          'session': 'first',
          'elapsedMs': index,
          'kind': 'stage',
          'stage': 'route.changed',
        });
      }
      report.add({
        'type': 'memoryAttribution',
        'runId': 'run',
        'processId': 2,
        'session': 'second',
        'elapsedMs': 0,
        'kind': 'snapshot',
        'owners': {},
      });
      final summary = report.toJson();
      final sessions = summary['sessions'] as List;
      expect(sessions, hasLength(2));
      expect((sessions.first as Map)['stages'], hasLength(64));
      expect((sessions.first as Map)['omittedStages'], 36);
    },
  );

  test(
    'transient source failure does not fabricate a close or replacement',
    () {
      final tracker = MemoryAttribution()
        ..observe(sample(0))
        ..observe(sample(1000, player: true));
      final broken = sample(2000, player: true);
      broken['sources'] = {
        'player.1': {'available': false},
      };
      expect(tracker.observe(broken), isEmpty);
      expect(tracker.observe(sample(3000, player: true)), isEmpty);
      final close = tracker.observe(sample(4000));
      expect(
        close.where((row) => row['stage'] == 'playback.closed'),
        hasLength(1),
      );
    },
  );

  test(
    'summary retains newest stages when rotated files arrive in reverse order',
    () {
      final report = MemoryAttributionReport();
      for (var tick = 99; tick >= 0; tick--) {
        report.add({
          'type': 'memoryAttribution',
          'runId': 'run',
          'processId': 1,
          'session': 'session',
          'elapsedMs': tick,
          'sequence': tick,
          'kind': 'stage',
          'stage': 'route.changed',
        });
      }
      final session = (report.toJson()['sessions'] as List).single as Map;
      final stages = session['stages'] as List;
      expect((stages.first as Map)['elapsedMs'], 36);
      expect((stages.last as Map)['elapsedMs'], 99);
    },
  );

  test(
    'active owners stay bounded when new players precede existing sources',
    () {
      final tracker = MemoryAttribution();
      Map<String, Object?> manyPlayers(int tick, List<int> identifiers) => {
        ...sample(tick),
        'sources': {
          for (final id in identifiers)
            'player.$id': {
              'session': {'runtimeId': id},
            },
        },
      };
      tracker.observe(manyPlayers(0, List.generate(8, (index) => index)));
      final events = tracker.observe(
        manyPlayers(5000, [
          ...List.generate(8, (index) => index + 8),
          ...List.generate(8, (index) => index),
        ]),
      );
      final snapshot = events.firstWhere((row) => row['kind'] == 'snapshot');
      expect(snapshot['activePlaybacks'], 8);
      expect(snapshot['omittedActivePlayers'], 8);
    },
  );
}
