import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

import 'density_metrics.dart';

class _Source implements DanmakuTimelineSource {
  _Source(this.cache);
  final DanmakuCache cache;
  @override
  Stream<DanmakuSourceChange> get changes => const Stream.empty();
  @override
  Future<void> ensureRange(int startUs, int endUs) async {}
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) =>
      cache.readRange(startUs, endUs, maxEntriesPerBucket: maxEntriesPerBucket);
}

Future<void> _snapshot(
  DanmakuWindowRenderer<DensityTag> renderer,
  String path,
  ui.Image? background,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xff252832), ui.BlendMode.src);
  if (background != null) {
    canvas.drawImageRect(
      background,
      Rect.fromLTWH(
        0,
        0,
        background.width.toDouble(),
        background.height.toDouble(),
      ),
      const Rect.fromLTWH(0, 0, 1280, 720),
      Paint(),
    );
  }
  renderer.paint(canvas, const Size(1280, 720));
  final picture = recorder.endRecording();
  final image = await picture.toImage(1280, 720);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'sweep real-font production renderer with real and synthetic density',
    () async {
      final output =
          Platform.environment['DANMAKU_RENDER_REPORT'] ??
          'build/danmaku-density/render';
      await Directory(output).create(recursive: true);
      final font = Platform.environment['DANMAKU_TEST_FONT'];
      final merge = Platform.environment['DANMAKU_TEST_MERGE'] == '1';
      final fps = int.parse(Platform.environment['DANMAKU_TEST_FPS'] ?? '60');
      final caps =
          (Platform.environment['DANMAKU_TEST_CAPS'] ?? '4,8,12,16,24,32,120')
              .split(',')
              .map(int.parse);
      final frames = (Platform.environment['DANMAKU_TEST_PREPARE'] ?? '4,8')
          .split(',')
          .map(int.parse);
      final tailSeconds = int.parse(
        Platform.environment['DANMAKU_TEST_TAIL_SECONDS'] ?? '8',
      );
      final selectedInputs = Platform.environment['DANMAKU_TEST_INPUTS']
          ?.split(',')
          .toSet();
      final windowIndex = int.parse(
        Platform.environment['DANMAKU_TEST_WINDOW'] ?? '0',
      );
      if (font != null) {
        await (FontLoader('DensityFont')..addFont(
              Future.value(
                ByteData.sublistView(await File(font).readAsBytes()),
              ),
            ))
            .load();
      }
      final inputs = <String, List<DanmakuElem>>{};
      final files =
          Platform.environment['DANMAKU_REAL_FILES']?.split('|') ?? [];
      for (var i = 0; i < files.length; i++) {
        final items = <DanmakuElem>[];
        await for (final batch in readDanmakuFile(File(files[i]))) {
          items.addAll(batch.where((e) => e.mode >= 1 && e.mode <= 6));
        }
        inputs['real${i + 1}'] = items;
      }
      inputs['synthetic'] = [
        for (var i = 0; i < 16000; i++)
          DanmakuElem(
            progress: i ~/ 40 * 100 + i % 40 * 2,
            content: '合成弹幕$i：高密度轨道验证',
            color: 0xffffff,
            mode: i % 15 == 0 ? 5 : 1,
            weight: i % 40 >= 36 ? 10 : i % 4 + 1,
          ),
      ];
      for (final low in [false, true]) {
        final weights = low ? [0, 1, 2, 3, 4] : [0, 3, 5, 7, 10];
        inputs[low ? 'relative_low' : 'relative_dense'] = [
          for (var step = 0; step < 300; step++)
            for (var group = 0; group < 5; group++)
              for (var i = 0; i < [10, 12, 7, 2, 2][group]; i++)
                DanmakuElem(
                  progress: step * 100,
                  content: '相对排序${step}_${group}_$i',
                  color: 0xffffff,
                  mode: 1,
                  weight: weights[group],
                ),
        ];
      }
      inputs['relative_slots'] = [
        for (var step = 0; step < 4; step++)
          for (var group = 0; group < 5; group++)
            for (var i = 0; i < [10, 12, 7, 2, 2][group]; i++)
              DanmakuElem(
                progress: step * 8000,
                content: '权重${[0, 3, 5, 7, 10][group]}：${step}_$i',
                color: 0xffffff,
                mode: 5,
                weight: [0, 3, 5, 7, 10][group],
              ),
      ];
      final reports = <Map<String, Object?>>[];
      for (final input in inputs.entries) {
        if (selectedInputs != null && !selectedInputs.contains(input.key)) {
          continue;
        }
        final slots = input.key == 'relative_slots';
        final buckets = <int, List<DanmakuElem>>{};
        for (final e in input.value) {
          (buckets[e.progress ~/ 100] ??= []).add(e);
        }
        final maxMs = input.value.map((e) => e.progress).reduce(math.max);
        var startMs = 0;
        var peakCount = 0;
        final windows = <({int startMs, int count})>[];
        for (var ms = 0; ms <= math.max(0, maxMs - 30000); ms += 1000) {
          var count = 0;
          for (var bucket = ms ~/ 100; bucket < ms ~/ 100 + 300; bucket++) {
            count += buckets[bucket]?.length ?? 0;
          }
          if (count > peakCount) {
            peakCount = count;
            startMs = ms;
          }
          windows.add((startMs: ms, count: count));
        }
        if (windowIndex > 0 &&
            !input.key.startsWith('relative') &&
            input.key != 'synthetic') {
          windows.sort((a, b) {
            final density = b.count.compareTo(a.count);
            return density != 0 ? density : a.startMs.compareTo(b.startMs);
          });
          final selected = <int>[];
          for (final window in windows) {
            if (selected.every((ms) => (ms - window.startMs).abs() >= 30000)) {
              selected.add(window.startMs);
              if (selected.length > windowIndex) break;
            }
          }
          if (selected.length <= windowIndex) throw ArgumentError('没有足够的不重叠时段');
          startMs = selected[windowIndex];
        }
        var region = input.value
            .where((e) => e.progress >= startMs && e.progress < startMs + 30000)
            .toList();
        if (merge) region = await mergeDanmakuInBackground(region);
        final backgroundFile = File('$output/${input.key}-background.png');
        ui.Image? background;
        if (backgroundFile.existsSync()) {
          final codec = await ui.instantiateImageCodec(
            await backgroundFile.readAsBytes(),
          );
          background = (await codec.getNextFrame()).image;
          codec.dispose();
        }
        final option = DanmakuOption(
          fontSize: 25,
          duration: 8,
          staticDuration: slots ? 8 : 5,
          safeArea: false,
        );
        var viewport = const Size(1280, 720);
        if (slots) {
          final measure = DanmakuWindowRenderer<DensityTag>(
            option: option,
            size: viewport,
            fontFamily: font == null ? null : 'DensityFont',
          );
          viewport = Size(
            1280,
            measure.rasters.measureTrackHeight() * 12 + .01,
          );
          measure.dispose();
        }
        for (final cap in caps) {
          for (final perFrame in frames) {
            final retention = DanmakuPriorityRetention(
              maxElements: 36000,
              maxPerBucket: cap,
              maxBytes: 20 * 1024 * 1024,
            );
            for (var i = 0; i < region.length; i++) {
              retention.add(i, region[i]);
            }
            final cache = DanmakuCache()
              ..addFileElements(retention.buckets.values.expand((e) => e));
            final source = _Source(cache);
            final renderer = DanmakuWindowRenderer<DensityTag>(
              option: option,
              size: viewport,
              fontFamily: font == null ? null : 'DensityFont',
            )..reset(startMs * 1000);
            final coordinator = DanmakuWindowCoordinator<DensityTag>(
              source: source,
              renderer: renderer,
              preparePerFrame: perFrame,
              maxCandidatesPerBucket: cap,
              contentOf: (e) => DanmakuContentItem<DensityTag>(
                e.content,
                color: Color(0xff000000 | (e.color == 0 ? 0xffffff : e.color)),
                type: e.mode == 5
                    ? DanmakuItemType.top
                    : e.mode == 4
                    ? DanmakuItemType.bottom
                    : DanmakuItemType.scroll,
                extra: (weight: e.weight, sourceMs: e.progress),
              ),
            );
            final metrics = DanmakuDensityMetrics(
              input: region,
              size: viewport,
            );
            final times = <int>[];
            var peakActive = 0;
            var peakBytes = 0;
            var incomplete = 0;
            var peakWindowItems = 0;
            var peakWindowBytes = 0;
            var coldPreparationFrames = 0;
            final preparationUs = <int>[];
            // 冷进入和稳态分开；等待阶段不移动媒体时间。
            for (
              var i = 0;
              i < 512 && renderer.validUntilUs < startMs * 1000 + 2000000;
              i++
            ) {
              final watch = Stopwatch()..start();
              coordinator.prepareFrame(renderer, startMs * 1000);
              preparationUs.add(watch.elapsedMicroseconds);
              coldPreparationFrames++;
            }
            for (var frame = 0; frame <= fps * (30 + tailSeconds); frame++) {
              final us = startMs * 1000 + frame * 1000000 ~/ fps;
              final watch = Stopwatch()..start();
              coordinator.prepareFrame(renderer, us);
              if (frame < fps * 30) {
                preparationUs.add(watch.elapsedMicroseconds);
              }
              renderer.present(us, allowUnprepared: true);
              if (frame < fps * 30) times.add(watch.elapsedMicroseconds);
              metrics.sample(renderer.interaction.snapshot, us);
              peakActive = math.max(peakActive, renderer.activeCount);
              peakBytes = math.max(peakBytes, renderer.workingSetBytes);
              peakWindowItems = math.max(
                peakWindowItems,
                renderer.statistics['windowItems']! as int,
              );
              peakWindowBytes = math.max(
                peakWindowBytes,
                renderer.statistics['windowBytes']! as int,
              );
              if (frame < fps * 30 && renderer.validUntilUs <= us) incomplete++;
              if (frame == fps * 10 &&
                  perFrame == 8 &&
                  [8, 12, 16, 24, 32, 120].contains(cap)) {
                await _snapshot(
                  renderer,
                  '$output/${input.key}-cap$cap.png',
                  background,
                );
              }
            }
            times.sort();
            preparationUs.sort();
            final visibility = metrics.summarize();
            final result = <String, Object?>{
              'name': input.key,
              'merge': merge,
              'fps': fps,
              'startMs': startMs,
              'windowIndex': windowIndex,
              'rangeElements': region.length,
              'cap': cap,
              'perFrame': perFrame,
              'retained': cache.elementCount,
              'inputByWeight': weightCounts(region),
              'retainedByWeight': weightCounts(
                retention.buckets.values.expand((e) => e),
              ),
              'tailSeconds': tailSeconds,
              'font': font == null
                  ? 'flutter_test_default'
                  : 'explicit_font_file',
              'viewport': [viewport.width, viewport.height],
              ...visibility,
              'peakActive': peakActive,
              'peakWorkingSetBytes': peakBytes,
              'peakWindowItems': peakWindowItems,
              'peakWindowBytes': peakWindowBytes,
              'coldPreparationFrames': coldPreparationFrames,
              'prepareP95Us':
                  preparationUs[(preparationUs.length * .95).floor()],
              'prepareMaxUs': preparationUs.last,
              'incompleteFrames': incomplete,
              'updateP95Us': times[(times.length * .95).floor()],
              'updateTotalUs': times.fold<int>(0, (a, b) => a + b),
              'scope':
                  'flutter_host_real_font_production_renderer_virtual_clock',
            };
            reports.add(result);
            // ignore: avoid_print
            print('DANMAKU_RENDER ${jsonEncode(result)}');
            coordinator.dispose();
            renderer.dispose();
          }
        }
        background?.dispose();
      }
      expect(reports, isNotEmpty);
      await File('$output/report.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
