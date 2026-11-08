import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/setting/decoder_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:window_manager/window_manager.dart';

const decoderTestWorkerArgument = '--piliaurora-decoder-test';
const _portKey = 'PILIAURORA_DECODER_TEST_PORT';
const _tokenKey = 'PILIAURORA_DECODER_TEST_TOKEN';

DecoderTestSession createDecoderTestSession(
  HwDecType decoder,
  VideoItem sample,
) => Platform.isWindows
    ? ProcessDecoderTestSession(decoder, sample)
    : NativeDecoderTestSession(decoder, sample);

/// 驱动的访问违规会直接终止进程，不能由 Dart 的 try/catch 隔离。
/// 每组使用独立进程；收到结果且进程正常退出后才确认测试完成。
class ProcessDecoderTestSession implements DecoderTestSession {
  ProcessDecoderTestSession(
    this.decoder,
    this.sample, {
    Future<Process> Function(Map<String, String>)? launch,
    this.budget = const Duration(seconds: 30),
  }) : _launch = launch ?? _startWorker;

  final HwDecType decoder;
  final VideoItem sample;
  final Duration budget;
  final Future<Process> Function(Map<String, String>) _launch;
  @override
  final videoController = ValueNotifier<VideoController?>(null);
  final _cancelled = Completer<void>();
  final _reply = Completer<DecoderTestResult>();
  HttpServer? _server;
  WebSocket? _socket;
  Future<Process>? _starting;
  Future<DecoderTestResult>? _running;
  Future<void>? _disposing;

  static Future<Process> _startWorker(Map<String, String> environment) =>
      Process.start(
        Platform.resolvedExecutable,
        [decoderTestWorkerArgument],
        workingDirectory: File(Platform.resolvedExecutable).parent.path,
        environment: environment,
      );

  @override
  Future<DecoderTestResult> run() => _running ??= _run();

  Future<DecoderTestResult> _run() async {
    if (_cancelled.isCompleted) return const DecoderTestResult.cancelled();
    try {
      return await Future.any([
        _execute().timeout(budget),
        _cancelled.future.then((_) => const DecoderTestResult.cancelled()),
      ]);
    } catch (error) {
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.error,
        'decoderTest',
        '测试进程未完成',
        details: {'decoder': decoder.hwdec, 'codec': sample.codecid},
      );
      return DecoderTestResult.failure(
        error is TimeoutException ? '测试进程超时' : '测试进程启动或通信失败',
      );
    } finally {
      await dispose();
    }
  }

  Future<DecoderTestResult> _execute() async {
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final server = _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    if (_cancelled.isCompleted) {
      await server.close(force: true);
      return const DecoderTestResult.cancelled();
    }
    server.listen((request) async {
      // 样片地址可能含签名；只交给持有本轮随机凭证的子进程。
      if (_cancelled.isCompleted ||
          _socket != null ||
          request.headers.value(HttpHeaders.authorizationHeader) != token ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        if (_cancelled.isCompleted || _socket != null) {
          await socket.close();
          return;
        }
        _socket = socket;
        socket
          ..listen(
            (data) {
              if (_reply.isCompleted) return;
              try {
                _reply.complete(_decodeResult(jsonDecode(data as String)));
              } catch (_) {
                _reply.complete(const DecoderTestResult.failure('测试进程结果无效'));
              }
            },
            onError: (Object error) {},
          )
          ..add(
            jsonEncode({
              'decoder': decoder.hwdec,
              'codec': sample.codecid,
              'url': sample.playUrls
                  .firstWhere((url) => url.trim().isNotEmpty)
                  .trim(),
              'width': sample.width,
              'height': sample.height,
              'videoSync': Pref.videoSync,
            }),
          );
      } catch (_) {
        if (!_reply.isCompleted) {
          _reply.complete(const DecoderTestResult.failure('测试进程连接失败'));
        }
      }
    });
    final process = await (_starting = _launch({
      _portKey: '${server.port}',
      _tokenKey: token,
    }));
    // 持续排空原生输出，避免管道填满阻塞驱动；结果走独立 IPC。
    unawaited(process.stdout.drain<void>().catchError((Object error) {}));
    unawaited(process.stderr.drain<void>().catchError((Object error) {}));
    if (_cancelled.isCompleted) process.kill();
    final code = await process.exitCode;
    if (_cancelled.isCompleted) return const DecoderTestResult.cancelled();
    if (code != 0) {
      final status =
          '0x${(code & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.error,
        'decoderTest',
        '测试进程异常退出',
        details: {
          'decoder': decoder.hwdec,
          'codec': sample.codecid,
          'exitCode': status,
        },
      );
      return DecoderTestResult.failure('解码测试进程异常退出（$status）');
    }
    return _reply.future.timeout(const Duration(seconds: 2));
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _cancelled.complete();
    unawaited(_socket?.close());
    await _server?.close(force: true);
    final starting = _starting;
    if (starting == null) return;
    Process process;
    try {
      process = await starting;
    } catch (_) {
      return;
    }
    process.kill();
    // 进程退出才表示操作系统已回收驱动上下文，不能只以 kill 返回值为准。
    await process.exitCode.timeout(const Duration(seconds: 5));
  }
}

Map<String, Object?> _encodeResult(DecoderTestResult result) => {
  'passed': result.passed,
  'cancelled': result.cancelled,
  'fallback': result.fallback,
  'decoder': result.decoder,
  'size': result.size,
  'speed': result.speed,
  'error': result.error,
  'cpu': result.performance?.averageCpu,
  'memory': result.performance?.peakMemoryMb,
};

DecoderTestResult _decodeResult(dynamic value) {
  final data = value as Map<String, dynamic>;
  if (data['cancelled'] == true) return const DecoderTestResult.cancelled();
  if (data['passed'] != true) {
    return DecoderTestResult.failure(
      data['error'] as String? ?? '解码测试失败',
      performance: DecoderPerformance(
        averageCpu: (data['cpu'] as num?)?.toDouble(),
        peakMemoryMb: (data['memory'] as num?)?.toDouble(),
      ),
    );
  }
  return DecoderTestResult.success(
    decoder: data['decoder'] as String,
    size: data['size'] as String,
    speed: (data['speed'] as num).toDouble(),
    fallback: data['fallback'] as bool,
    performance: DecoderPerformance(
      averageCpu: (data['cpu'] as num?)?.toDouble(),
      peakMemoryMb: (data['memory'] as num?)?.toDouble(),
    ),
  );
}

/// 在正常启动、账号和单实例检查之前分流，仅使用本轮传入的播放设置。
Future<void> runDecoderTestWorker() async {
  WebSocket? socket;
  NativeDecoderTestSession? session;
  try {
    final port = int.parse(Platform.environment[_portKey]!);
    final token = Platform.environment[_tokenKey]!;
    socket = await WebSocket.connect(
      'ws://127.0.0.1:$port',
      headers: {HttpHeaders.authorizationHeader: token},
    ).timeout(const Duration(seconds: 5));
    final messages = StreamIterator(socket);
    if (!await messages.moveNext().timeout(const Duration(seconds: 5))) {
      exit(1);
    }
    final input =
        jsonDecode(messages.current as String) as Map<String, dynamic>;
    final decoder = HwDecType.values.firstWhere(
      (type) => type.hwdec == input['decoder'],
    );
    final codec = input['codec'] as int;
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();
    MediaKit.ensureInitialized();
    GStorage.setting = await Hive.openBox('decoder-test', bytes: Uint8List(0));
    await GStorage.setting.put(SettingBoxKey.videoSync, input['videoSync']);
    session = NativeDecoderTestSession(
      decoder,
      VideoItem(
        id: 80,
        codecid: codec,
        baseUrl: input['url'] as String,
        quality: VideoQuality.high1080,
        width: input['width'] as int?,
        height: input['height'] as int?,
      ),
    );
    final active = session;
    // 父进程退出或停止测试时，连接关闭也会终止子进程。
    unawaited(
      messages.moveNext().then(
        (_) => exit(0),
        onError: (Object error) => exit(1),
      ),
    );
    await windowManager.setSize(const Size(480, 320));
    await windowManager.setTitle('解码测试 · ${decoderTestLabel(decoder)}');
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: ValueListenableBuilder<VideoController?>(
            valueListenable: active.videoController,
            builder: (_, controller, _) => controller == null
                ? const Center(child: CircularProgressIndicator())
                : Video(controller: controller),
          ),
        ),
      ),
    );
    await windowManager.show();
    final result = await active.run();
    await active.dispose();
    socket.add(jsonEncode(_encodeResult(result)));
    await socket.close();
    await Hive.close();
    exit(0);
  } catch (_) {
    // 原生驱动访问违规不会到达这里，由父进程按退出码报告。
    await session?.dispose();
    await socket?.close();
    exit(1);
  }
}
