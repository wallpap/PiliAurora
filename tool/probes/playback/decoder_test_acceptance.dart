import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/setting/decoder_test.dart';
import 'package:pili_aurora/pages/setting/decoder_test_process.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:window_manager/window_manager.dart';

/// 以本地样片验收设置页使用的实际测试会话，不读取账号或现用设置。
Future<void> main(List<String> arguments) async {
  if (arguments.firstOrNull == decoderTestWorkerArgument) {
    await runDecoderTestWorker();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) await windowManager.ensureInitialized();
  MediaKit.ensureInitialized();
  const config = String.fromEnvironment('DECODER_TEST_CONFIG');
  const output = String.fromEnvironment('DECODER_TEST_REPORT');
  final inputs = jsonDecode(await File(config).readAsString()) as List;
  GStorage.setting = await Hive.openBox('decoder-test', bytes: Uint8List(0));
  final active = ValueNotifier<DecoderTestSession?>(null);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<DecoderTestSession?>(
            valueListenable: active,
            builder: (_, session, _) => session == null
                ? const Text('解码测试验收')
                : ValueListenableBuilder<VideoController?>(
                    valueListenable: session.videoController,
                    builder: (_, controller, _) => controller == null
                        ? const CircularProgressIndicator()
                        : Video(controller: controller),
                  ),
          ),
        ),
      ),
    ),
  );
  final results = <Map<String, Object?>>[];
  for (final input in inputs.cast<Map<String, dynamic>>()) {
    final file = File(input['path'] as String);
    if (!file.existsSync()) throw ArgumentError('需要存在的本地样片');
    final modes =
        (input['decoders'] as List?)?.cast<String>() ??
        ['no', 'd3d11va', 'd3d11va-copy'];
    for (final mode in modes) {
      final decoder = HwDecType.values.firstWhere((type) => type.hwdec == mode);
      final session = createDecoderTestSession(
        decoder,
        VideoItem(
          id: 80,
          codecid: input['codec'] as int,
          baseUrl: file.absolute.path,
          quality: VideoQuality.high1080,
          width: input['width'] as int?,
          height: input['height'] as int?,
        ),
      );
      active.value = session;
      final result = await session.run();
      final row = <String, Object?>{
        'codec': input['codec'],
        'requested': decoder.hwdec,
        'passed': result.passed,
        'fallback': result.fallback,
        'actual': result.decoder,
        'size': result.size,
        'speed': result.speed,
        'error': result.error,
      };
      try {
        await session.dispose();
      } catch (error) {
        row['releaseError'] = '$error';
      }
      active.value = null;
      results.add(row);
      final report = File(output);
      await report.parent.create(recursive: true);
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(results),
      );
      stdout.writeln(jsonEncode(row));
    }
  }
  await Hive.close();
  exit(
    results.every(
          (row) => row['passed'] == true && !row.containsKey('releaseError'),
        )
        ? 0
        : 1,
  );
}
