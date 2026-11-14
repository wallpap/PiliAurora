import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/services/diagnostics/memory_attribution.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
      'Usage: memory_attribution_benchmark <extracted diagnostic directory> ...',
    );
    exitCode = 64;
    return;
  }
  final sessions = <String, List<Map<String, Object?>>>{};
  for (final argument in arguments) {
    await for (final file in Directory(argument).list()) {
      if (file is! File ||
          !file.uri.pathSegments.last.startsWith('performance.jsonl')) {
        continue;
      }
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final record = jsonDecode(line) as Map<String, Object?>;
        if (record['type'] != 'sample') continue;
        final identity = jsonEncode([
          record['runId'],
          record['processId'],
          record['session'],
        ]);
        sessions.putIfAbsent(identity, () => []).add(record);
      }
    }
  }
  for (final records in sessions.values) {
    records.sort(
      (before, after) =>
          (before['elapsedMs'] as int).compareTo(after['elapsedMs'] as int),
    );
  }
  final latencies = <int>[];
  var snapshots = 0, stages = 0, encodedBytes = 0;
  for (var round = 0; round < 6; round++) {
    for (final records in sessions.values) {
      final tracker = MemoryAttribution();
      for (final record in records) {
        final watch = Stopwatch()..start();
        final output = tracker.observe(record);
        watch.stop();
        if (round > 0) latencies.add(watch.elapsedMicroseconds);
        if (round == 5) {
          for (final event in output) {
            if (event['kind'] == 'snapshot') snapshots++;
            if (event['kind'] == 'stage') stages++;
            encodedBytes += utf8.encode(jsonEncode(event)).length;
          }
        }
      }
    }
  }
  latencies.sort();
  if (latencies.isEmpty) throw StateError('No performance samples');
  num percentile(double fraction) =>
      latencies[((latencies.length - 1) * fraction).floor()];
  stdout.writeln(
    jsonEncode({
      'scope': 'collectorOnly; excludesExistingReadersAndSerialization; notLiveFrameAcceptance',
      'inputSamples': sessions.values.fold<int>(
        0,
        (total, records) => total + records.length,
      ),
      'sessions': sessions.length,
      'timedCalls': latencies.length,
      'meanUs':
          latencies.fold<int>(0, (total, value) => total + value) /
          latencies.length,
      'p50Us': percentile(.5),
      'p95Us': percentile(.95),
      'p99Us': percentile(.99),
      'maxUs': latencies.last,
      'snapshotsPerReplay': snapshots,
      'stagesPerReplay': stages,
      'additionalPayloadBytesPerReplay': encodedBytes,
    }),
  );
}
