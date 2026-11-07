import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';

import 'density_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compare processed source budgets on full segments', () async {
    final sources = <String, Map<int, List<DanmakuElem>>>{};
    final files = Platform.environment['DANMAKU_REAL_FILES']?.split('|') ?? [];
    for (var i = 0; i < files.length; i++) {
      final segments = <int, List<DanmakuElem>>{};
      await for (final batch in readDanmakuFile(File(files[i]))) {
        for (final e in batch) {
          if (e.mode >= 1 && e.mode <= 6) {
            (segments[e.progress ~/ 360000] ??= []).add(e);
          }
        }
      }
      sources['real${i + 1}'] = segments;
    }
    sources['synthetic6min'] = {
      0: [
        for (var i = 0; i < 144000; i++)
          DanmakuElem(
            progress: i ~/ 40 * 100,
            content: '六分钟预算压力$i',
            weight: i % 40 >= 36 ? 10 : i % 4 + 1,
            mode: 1,
          ),
      ],
    };
    final reports = <Map<String, Object?>>[];
    for (final source in sources.entries) {
      for (final segment in source.value.entries) {
        for (final limits in [(16, 30000), (20, 36000), (24, 42000)]) {
          for (final cap in [8, 12, 16, 120]) {
            final watch = Stopwatch()..start();
            final retention = DanmakuPriorityRetention(
              maxElements: limits.$2,
              maxPerBucket: cap,
              maxBytes: limits.$1 * 1024 * 1024,
              baseBytes: 128,
            );
            for (var i = 0; i < segment.value.length; i++) {
              retention.add(i, segment.value[i]);
            }
            final kept = retention.buckets.values.expand((e) => e).toList();
            expect(
              retention.estimatedBytes,
              lessThanOrEqualTo(limits.$1 * 1024 * 1024),
            );
            expect(kept.length, lessThanOrEqualTo(limits.$2));
            final result = <String, Object?>{
              'name': source.key,
              'segment': segment.key,
              'mib': limits.$1,
              'maxElements': limits.$2,
              'cap': cap,
              'input': segment.value.length,
              'retained': kept.length,
              'estimatedBytes': retention.estimatedBytes,
              'inputByWeight': weightCounts(segment.value),
              'retainedByWeight': weightCounts(kept),
              'elapsedUs': watch.elapsedMicroseconds,
              'scope': 'flutter_host_priority_retention_unmerged_full_segment',
            };
            reports.add(result);
          }
        }
      }
    }
    final path =
        Platform.environment['DANMAKU_BUDGET_REPORT'] ??
        'build/danmaku-relative-20261107/budgets.json';
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(reports),
    );
    // ignore: avoid_print
    print('DANMAKU_BUDGET_CASES ${reports.length}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
