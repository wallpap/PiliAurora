import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pili_aurora/services/diagnostics/flutter_graphics_metrics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:window_manager/window_manager.dart';

const _channel = MethodChannel(
  'pili_aurora/graphics_memory',
  JSONMethodCodec(),
);
const _empty = ColoredBox(color: Color(0xff16191e));
const _deviceChannel = MethodChannel(
  'pili_aurora/graphics_device',
  JSONMethodCodec(),
);

/// 无账号、网络及用户数据的独立合成负载；不能代替真实应用留存验证。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final actions =
      (Platform.environment['PILIAURORA_GRAPHICS_ACTIONS'] ??
              'purgeRaster,purgeIO,flushIO,flushRaster,trim')
          .split(',')
          .map((action) => action.trim())
          .where((action) => action.isNotEmpty)
          .toList();
  final controlSeconds =
      (int.tryParse(
                Platform.environment['PILIAURORA_GRAPHICS_CONTROL_SECONDS'] ??
                    '',
              ) ??
              4)
          .clamp(1, 600);
  final output = File(
    Platform.environment['PILIAURORA_GRAPHICS_OUTPUT'] ??
        '${File(Platform.resolvedExecutable).parent.path}/graphics-probe.json',
  );
  final clock = Stopwatch()..start();
  final process = ProcessMetrics();
  final graphics = FlutterGraphicsMetrics();
  final images = <ui.Image>[];
  var decoded = 0;
  var explicitlyDisposed = 0;
  final stages = <String, Map<String, Object?>>{};
  final report = <String, Object?>{
    'schemaVersion': 1,
    'state': 'running',
    'workload': '64 decoded 512x512 PNG images in a 1024x640 window',
    'scope': 'syntheticOnly; doesNotProveRealApplicationRetentionFixed',
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'stages': stages,
    'passed': false,
    'retentionTargetPassed': false,
    'actions': actions,
    'controlSeconds': controlSeconds,
    'contextBytesSemantics': 'sumForGrowthCheckOnly; rasterAndIOCanShareDuplicatedBacking; notUniqueGpuBytes',
  };
  Future<void> progress() async {
    await output.parent.create(recursive: true);
    await File('${output.parent.path}/progress.json').writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert({...report, 'finalReport': report['state'] != 'running'}),
    );
  }

  Future<Map<String, Object?>> native(String method, [String? context]) async {
    try {
      return await _channel
              .invokeMapMethod<String, Object?>(method, {
                if (context != null) 'context': context else 'resources': true,
              })
              .timeout(const Duration(seconds: 10)) ??
          const {'status': 'empty'};
    } on MissingPluginException {
      return const {'status': 'unsupported'};
    } catch (error) {
      return {'status': 'error', 'error': error.toString()};
    }
  }

  Future<void> record(
    String name, {
    String? action,
    Map<String, Object?>? receipt,
  }) async {
    final nativeResult = await native('sample');
    stages[name] = {
      'action': ?action,
      'receipt': ?receipt,
      'elapsedMs': clock.elapsedMilliseconds,
      'time': DateTime.now().toUtc().toIso8601String(),
      'process': process.sample(),
      'flutterGraphics': graphics.snapshot(),
      'ownDecodedImages': decoded,
      'ownExplicitlyDisposedImages': explicitlyDisposed,
      'ownLiveDecodedImages': images.length,
      'native': nativeResult,
      'views': [
        for (final view in ui.PlatformDispatcher.instance.views)
          {
            'physicalWidth': view.physicalSize.width,
            'physicalHeight': view.physicalSize.height,
            'devicePixelRatio': view.devicePixelRatio,
          },
      ],
    };
    await progress();
  }

  Future<void> detachAndDispose() async {
    runApp(_empty);
    await _frame();
    // 仅释放此入口自己创建并持有的句柄，绝不遍历框架或别人的对象。
    while (images.isNotEmpty) {
      images.removeLast().dispose();
      explicitlyDisposed++;
    }
  }

  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1024, 640));
    await windowManager.setResizable(false);
    await windowManager.setTitle('PiliAurora graphics memory probe');
    graphics.start();
    runApp(_empty);
    await windowManager.show();
    await _frame();
    await Future<void>.delayed(const Duration(seconds: 4));
    await record('baseline');

    for (var i = 0; i < 64; i++) {
      images.add(await _decodeImage(i));
      decoded++;
    }
    final grid = _Grid(images);
    runApp(CustomPaint(painter: grid, child: const SizedBox.expand()));
    await _frame();
    await Future<void>.delayed(const Duration(seconds: 5));
    await record('loaded');

    await detachAndDispose();
    await Future<void>.delayed(const Duration(seconds: 4));
    await record('detachedAndImagesDisposed');
    for (final (index, action) in actions.indexed) {
      Map<String, Object?> receipt;
      if (action == 'trim') {
        try {
          receipt =
              await _deviceChannel
                  .invokeMapMethod<String, Object?>('trim')
                  .timeout(const Duration(seconds: 10)) ??
              const {'status': 'empty'};
        } on MissingPluginException {
          receipt = const {'status': 'unsupported'};
        } catch (error) {
          receipt = {
            'status': 'error',
            'errorType': error.runtimeType.toString(),
          };
        }
      } else if (RegExp(r'^cache\d+$').hasMatch(action)) {
        final cache = PaintingBinding.instance.imageCache;
        final before = cache.maximumSizeBytes;
        cache.maximumSizeBytes = int.parse(action.substring(5)) * 1024 * 1024;
        receipt = {
          'status': 'cacheLimitChanged',
          'before': before,
          'after': cache.maximumSizeBytes,
          'currentSize': cache.currentSize,
          'currentSizeBytes': cache.currentSizeBytes,
        };
      } else if (action == 'frame') {
        WidgetsBinding.instance.scheduleFrame();
        var complete = true;
        try {
          await WidgetsBinding.instance.endOfFrame.timeout(
            const Duration(seconds: 3),
          );
        } on TimeoutException {
          complete = false;
        }
        receipt = {'status': 'frameRequested', 'complete': complete};
      } else if (action == 'clearImages') {
        PaintingBinding.instance.imageCache.clear();
        receipt = const {'status': 'cleared', 'clearLiveImages': false};
      } else {
        final context = const {
          'purgeRaster': 'raster',
          'purgeIO': 'io',
          'purgeRasterCache': 'rasterCache',
          'flushIO': 'flushIO',
          'flushRaster': 'flushRaster',
        }[action];
        if (context == null) throw ArgumentError.value(action, 'action');
        receipt = await native('purge', context);
      }
      await Future<void>.delayed(Duration(seconds: controlSeconds));
      await record(
        'action${index + 1}:$action',
        action: action,
        receipt: receipt,
      );
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    await record('settled');

    final baseline = _resourceBytes(stages['baseline']!);
    final loaded = _resourceBytes(stages['loaded']!);
    final supported = stages.values.every(
      (stage) => (stage['native'] as Map)['status'] == 'sampled',
    );
    final increased = loaded > baseline;
    final disposed =
        decoded == 64 && explicitlyDisposed == decoded && images.isEmpty;
    report['checks'] = {
      'engineSupported': supported,
      'loadedResourceBytesIncreased': increased,
      'baselineResourceBytes': baseline,
      'loadedResourceBytes': loaded,
      'ownImagesExplicitlyDisposed': disposed,
      'gridPaintCount': grid.paintCount,
    };
    report['passed'] =
        supported && increased && disposed && grid.paintCount > 0;
    final memory = stages['settled']!['process'] as Map;
    final rss = memory['rssBytes'] as int?;
    final private = memory['privateBytes'] as int?;
    report['retentionTarget'] = {
      'scope': 'syntheticProcessOnly',
      'limitBytes': 500 * 1024 * 1024,
      'rssBytes': rss,
      'privateBytes': private,
    };
    report['retentionTargetPassed'] =
        rss != null &&
        private != null &&
        rss < 500 * 1024 * 1024 &&
        private < 500 * 1024 * 1024;
  } catch (error, stack) {
    report['state'] = 'failed';
    report['error'] = error.toString();
    report['stack'] = stack.toString();
  } finally {
    try {
      await detachAndDispose();
      report['cleanup'] = {
        'ownLiveDecodedImages': images.length,
        'ownExplicitlyDisposedImages': explicitlyDisposed,
        'flutterGraphics': graphics.snapshot(),
      };
      await record('finalSnapshot', action: 'finalReadOnlySnapshot');
    } catch (error) {
      report['state'] = 'failed';
      report['cleanupError'] = error.toString();
    }
    graphics.stop();
    report['elapsedMs'] = clock.elapsedMilliseconds;
    try {
      if (report['state'] == 'running') report['state'] = 'completed';
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      await progress();
    } finally {
      // 正常窗口销毁路径让 runner 释放插件及 COM，不能使用 dart:io exit。
      await windowManager.destroy();
    }
  }
}

Future<void> _frame() async {
  WidgetsBinding.instance.scheduleFrame();
  try {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 3),
    );
  } on TimeoutException {
    // 隐藏或最小化窗口可能暂停帧，避免无人值守探针永久挂起。
  }
}

Future<ui.Image> _decodeImage(int index) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      paint.color = Color(
        0xff000000 | (((index + 1) * 7919 + x * 31337 + y * 65521) & 0xffffff),
      );
      canvas.drawRect(Rect.fromLTWH(x * 16, y * 16, 16, 16), paint);
    }
  }
  final picture = recorder.endRecording();
  ui.Image? source;
  try {
    source = await picture.toImage(512, 512);
    final png = await source.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('PNG encoding failed');
    final codec = await ui.instantiateImageCodec(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    source?.dispose();
    picture.dispose();
  }
}

int _resourceBytes(Map<String, Object?> stage) {
  final contexts = (stage['native'] as Map)['contexts'] as Map?;
  var bytes = 0;
  for (final context in const ['raster', 'io']) {
    final value = contexts?[context] as Map?;
    if (value?['available'] == true) {
      bytes += (value?['resourceBytes'] as num?)?.toInt() ?? 0;
    }
  }
  return bytes;
}

class _Grid extends CustomPainter {
  _Grid(this.images);
  final List<ui.Image> images;
  int paintCount = 0;
  @override
  void paint(Canvas canvas, Size size) {
    paintCount++;
    canvas.drawColor(const Color(0xff16191e), BlendMode.src);
    final paint = Paint()..filterQuality = FilterQuality.low;
    for (var i = 0; i < images.length; i++) {
      canvas.drawImageRect(
        images[i],
        const Rect.fromLTWH(0, 0, 512, 512),
        Rect.fromLTWH(
          (i % 8) * size.width / 8,
          (i ~/ 8) * size.height / 8,
          size.width / 8,
          size.height / 8,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _Grid oldDelegate) => true;
}
