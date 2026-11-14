import 'native_fixture_support.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';

// 将独立的 Flutter 完整解码作为参照，避免只拿区域后端和自身对照。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  observeNativeWorkers();
  final fixtures = nativeFixtures;
  const ids = [
    'wide',
    'tall',
    'png',
    'jpeg',
    'webp',
    'alpha',
    'webp-alpha',
    'icc-jpeg',
    'icc-webp',
    'small',
    'lossless',
    'progressive',
  ];
  final results = <Map<String, Object?>>[];
  final output = File(
    Platform.environment['REGION_FIDELITY_RESULT'] ??
        'build/probes/image-region/flutter-fidelity.json',
  );
  for (final id in ids) {
    nativeTest(
      'native original-scale $id agrees with Flutter reference',
      () async {
        final fixture = fixtures.cast<Map>().singleWhere(
          (row) => row['id'] == id,
        );
        final file = File(fixture['file'] as String);
        final directory = await Directory.systemTemp.createTemp(
          'region-fidelity-',
        );
        final store = ImageSourceStore(Directory('${directory.path}/source'));
        final lease = await store.acquire(file);
        NativeWorkerDecoder? decoder;
        ui.Codec? codec;
        ui.Image? reference;
        try {
          codec = await ui.instantiateImageCodec(await file.readAsBytes());
          reference = (await codec.getNextFrame()).image;
          codec.dispose();
          codec = null;
          decoder = await NativeWorkerDecoder.open(lease);
          final width = reference.width, height = reference.height;
          expect(decoder.sourceSize.width.toInt(), width);
          expect(decoder.sourceSize.height.toInt(), height);
          final w = math.min(257, width), h = math.min(259, height);
          for (final origin in [
            (0, 0),
            ((width - w) ~/ 2, (height - h) ~/ 2),
            (width - w, height - h),
          ]) {
            final x = origin.$1 & ~1, y = origin.$2 & ~1;
            final rect = ui.Rect.fromLTWH(
              x.toDouble(),
              y.toDouble(),
              w.toDouble(),
              h.toDouble(),
            );
            // 原始 Image 的字节可仍处于来源 ICC 空间；先经过 Flutter 绘制再比较显示像素。
            final recorder = ui.PictureRecorder();
            ui.Canvas(recorder).drawImageRect(
              reference,
              rect,
              ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
              ui.Paint(),
            );
            final picture = recorder.endRecording();
            final rendered = await picture.toImage(w, h);
            picture.dispose();
            final pixels = (await rendered.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            rendered.dispose();
            final left = math.max(0, x - 2), top = math.max(0, y - 2);
            final right = math.min(width, x + w + 2),
                bottom = math.min(height, y + h + 2);
            final read = ui.Rect.fromLTRB(
              left.toDouble(),
              top.toDouble(),
              right.toDouble(),
              bottom.toDouble(),
            );
            final region = await decoder.decodeRegion(
              RegionRequest(level: 0, core: rect, read: read),
            );
            try {
              final actual = (await region.image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              var maximum = 0, different = 0, total = 0, overThree = 0;
              final channelTotals = [0, 0, 0, 0];
              var maximumAt = <int>[];
              var maximumReference = <int>[];
              var maximumActual = <int>[];
              for (var row = 0; row < h; row++) {
                for (var column = 0; column < w * 4; column++) {
                  final delta =
                      (actual.getUint8(
                                ((row + y - top) * region.image.width +
                                            x -
                                            left) *
                                        4 +
                                    column,
                              ) -
                              pixels.getUint8(row * w * 4 + column))
                          .abs();
                  if (delta > maximum) {
                    final pixel = column ~/ 4;
                    maximumAt = [x + pixel, y + row];
                    maximumReference = List.generate(
                      4,
                      (c) => pixels.getUint8((row * w + pixel) * 4 + c),
                    );
                    maximumActual = List.generate(
                      4,
                      (c) => actual.getUint8(
                        ((row + y - top) * region.image.width +
                                    x -
                                    left +
                                    pixel) *
                                4 +
                            c,
                      ),
                    );
                  }
                  maximum = math.max(maximum, delta);
                  channelTotals[column % 4] += delta;
                  total += delta;
                  if (delta != 0) different++;
                  if (delta > 3) overThree++;
                }
              }
              results.add({
                'id': id,
                'origin': [x, y],
                'width': w,
                'height': h,
                'maximum': maximum,
                'mean': total / (w * h * 4),
                'differentChannels': different,
                'channelsOverThree': overThree,
                'sourceColorSpace': reference.colorSpace.name,
                'channelTotals': channelTotals,
                'maximumAt': maximumAt,
                'reference': maximumReference,
                'actual': maximumActual,
              });
              await output.writeAsString(
                const JsonEncoder.withIndent('  ').convert(results),
              );
              expect(maximum, lessThanOrEqualTo(3), reason: '$id at [$x,$y]');
            } finally {
              region.dispose();
            }
          }
        } finally {
          reference?.dispose();
          codec?.dispose();
          decoder?.dispose();
          if (decoder != null) await decoder.drained;
          await lease.dispose();
          await store.clear();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
