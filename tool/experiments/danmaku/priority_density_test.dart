import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/arrangement.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';

// 真实文件通过 DANMAKU_REAL_FILES（| 分隔）传入，仅输出聚合统计。
// DANMAKU_DENSITY_REPORT 指定本地 JSON；不将弹幕正文写入报告。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compare dense real and synthetic timelines', () async {
    final inputs = <String, List<DanmakuElem>>{};
    final files = Platform.environment['DANMAKU_REAL_FILES']?.split('|') ?? [];
    for (var i = 0; i < files.length; i++) {
      final elements = <DanmakuElem>[];
      await for (final batch in readDanmakuFile(File(files[i]))) {
        elements.addAll(batch);
      }
      inputs['real${i + 1}'] = elements;
    }
    inputs['synthetic'] = [
      for (var i = 0; i < 24000; i++)
        DanmakuElem(
          progress: i ~/ 40 * 100 + i % 40 * 2,
          content: '合成弹幕$i',
          mode: i % 15 == 0 ? 5 : 1,
          weight: i % 40 >= 36 ? 10 : i % 4 + 1,
        ),
    ];
    final results = <Map<String, Object?>>[];
    for (final input in inputs.entries) {
      final weights = <int, int>{};
      final buckets = <int, int>{};
      final seconds = <int, int>{};
      for (final element in input.value) {
        weights.update(element.weight, (v) => v + 1, ifAbsent: () => 1);
        buckets.update(
          element.progress ~/ 100,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
        seconds.update(
          element.progress ~/ 1000,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
      final peak = seconds.entries.reduce((a, b) => a.value >= b.value ? a : b);
      final startMs = math.max(0, peak.key * 1000 - 10000);
      final cache = DanmakuCache()
        ..addFileElements(
          input.value.where(
            (e) => e.progress >= startMs && e.progress < startMs + 30000,
          ),
        );
      final watch = Stopwatch()..start();
      final planner = DanmakuWindowPlanner<int>(
        option: const DanmakuOption(duration: 8, fontSize: 25, safeArea: false),
        width: 1280,
        trackHeight: 30,
        trackCount: 23,
      );
      final times = <int>[];
      var selected = 0;
      var highSelected = 0;
      var accepted = 0;
      var highAccepted = 0;
      final acceptedByWeight = <int, int>{};
      var maxWindow = 0;
      var id = 0;
      for (var ms = startMs; ms < startMs + 30000; ms += 100) {
        final entries = cache
            .readRange(
              ms * 1000,
              (ms + 100) * 1000,
              maxEntriesPerBucket: DanmakuDisplayLimits.maxPerBatch,
            )
            .entries;
        final ranked = entries.indexed.toList()
          ..sort((a, b) {
            final priority = compareDanmakuPriority(a.$2.element, b.$2.element);
            return priority != 0 ? priority : a.$1.compareTo(b.$1);
          });
        for (var offset = 0; offset < entries.length; offset += 4) {
          final slice = ranked.skip(offset).take(4).map((e) => e.$2).toList()
            ..sort((a, b) => a.positionUs.compareTo(b.positionUs));
          final candidates = [
            for (final e in slice)
              DanmakuMeasuredCandidate<int>(
                identity: id++,
                sourceUs: e.positionUs,
                width: math.min(1100, e.element.content.runes.length * 25.0),
                height: 30,
                type: e.element.mode == 5
                    ? DanmakuItemType.top
                    : e.element.mode == 4
                    ? DanmakuItemType.bottom
                    : DanmakuItemType.scroll,
                payload: e.element.weight,
                weight: e.element.weight,
              ),
          ];
          selected += candidates.length;
          highSelected += candidates.where((e) => e.payload >= 8).length;
          final batchWatch = Stopwatch()..start();
          expect(
            planner.prepare(
              candidates,
              generation: planner.window.generation,
              preparedUntilUs: (ms + 100) * 1000,
            ),
            isTrue,
          );
          times.add(batchWatch.elapsedMicroseconds);
        }
        planner.prepare(
          const [],
          generation: planner.window.generation,
          preparedUntilUs: (ms + 100) * 1000,
        );
        final decisions = planner.window.preparedItems.where(
          (e) => e.sourceUs >= ms * 1000,
        );
        accepted += decisions.where((e) => e.payload.accepted).length;
        highAccepted += decisions
            .where(
              (e) => e.payload.accepted && e.payload.candidate.payload >= 8,
            )
            .length;
        for (final item in decisions.where((item) => item.payload.accepted)) {
          acceptedByWeight.update(
            item.payload.candidate.weight,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        maxWindow = math.max(maxWindow, planner.window.length);
        planner.window.trimBefore(math.max(0, (ms - 2000) * 1000));
      }
      times.sort();
      final result = <String, Object?>{
        'name': input.key,
        'elements': input.value.length,
        'weightCounts': {for (final e in weights.entries) '${e.key}': e.value},
        'peak100ms': buckets.values.reduce(math.max),
        'peakSecond': peak.key,
        'peakPerSecond': peak.value,
        'rangeStartMs': startMs,
        'selected': selected,
        'highSelected': highSelected,
        'accepted': accepted,
        'highAccepted': highAccepted,
        // 保留旧统计字段便于对照；准入规则使用相对排序，不使用该诊断分界。
        'highWeightDiagnosticThreshold': 8,
        'acceptedByWeight': {
          for (final e in acceptedByWeight.entries) '${e.key}': e.value,
        },
        'prepareP95Us': times.isEmpty ? 0 : times[(times.length * .95).floor()],
        'prepareTotalUs': times.fold<int>(0, (a, b) => a + b),
        'maxWindow': maxWindow,
        'elapsedMs': watch.elapsedMilliseconds,
        'scope': 'flutter_host_planner_estimated_text_width',
      };
      results.add(result);
      // ignore: avoid_print
      print('DANMAKU_DENSITY ${jsonEncode(result)}');
    }
    final path = Platform.environment['DANMAKU_DENSITY_REPORT'];
    if (path != null) {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
      );
    }
  });
}
