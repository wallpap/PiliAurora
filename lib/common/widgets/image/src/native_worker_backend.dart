import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

final nativeWorkers = <NativeWorkerDecoder>{};

class _WorkerOutput {
  _WorkerOutput(Stream<List<int>> stream) : _chunks = StreamIterator(stream);
  final StreamIterator<List<int>> _chunks;
  List<int> _chunk = const [];
  int _position = 0;

  Future<void> _fill() async {
    while (_position >= _chunk.length) {
      if (!await _chunks.moveNext()) throw StateError('区域解码进程提前退出');
      _chunk = _chunks.current;
      _position = 0;
    }
  }

  Future<String> line() async {
    final bytes = <int>[];
    while (true) {
      await _fill();
      final newline = _chunk.indexOf(10, _position);
      final end = newline < 0 ? _chunk.length : newline;
      if (bytes.length + end - _position > 16384) {
        throw StateError('区域解码响应头超限');
      }
      bytes.addAll(_chunk.sublist(_position, end));
      _position = end;
      if (newline >= 0) {
        _position++;
        return utf8.decode(bytes);
      }
    }
  }

  Future<Uint8List> pixels(int length) async {
    final bytes = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      await _fill();
      final remaining = length - offset;
      final available = _chunk.length - _position;
      final count = remaining < available ? remaining : available;
      bytes.setRange(offset, offset + count, _chunk, _position);
      offset += count;
      _position += count;
    }
    return bytes;
  }

  Future<void> cancel() => _chunks.cancel();
}

/// 准备后未请求像素的邻页也持有进程，由会话关闭它。
class PreparedNativeBackend implements OwnedRegionImageBackend {
  PreparedNativeBackend(this.decoder);
  final NativeWorkerDecoder decoder;

  @override
  Future<RegionImageDecoder> open(ImageSourceLease source) async => decoder;

  @override
  Future<void> close() async {
    decoder.dispose();
    await decoder.drained;
  }
}

class NativeWorkerDecoder implements DrainingRegionImageDecoder {
  NativeWorkerDecoder._(
    this.process,
    this._lines,
    this._source,
    this.metadata,
  ) {
    // 提前观察错误，关闭时无人等待也不会产生未处理的异步错误。
    unawaited(
      _closed.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    nativeWorkers.add(this);
    _report('open', metadata);
  }

  static final _executableKey = Object();
  static final _bundledExecutable = path.join(
    path.dirname(Platform.resolvedExecutable),
    'piliaurora_image_worker.exe',
  );
  static final _bundledAvailable =
      Platform.isWindows && File(_bundledExecutable).existsSync();

  static String? get executable {
    final override = Zone.current[_executableKey];
    if (override == false) return null;
    if (override is String) return override;
    return _bundledAvailable ? _bundledExecutable : null;
  }

  @visibleForTesting
  static R runWith<R>(String? executable, R Function() action) =>
      runZoned(action, zoneValues: {_executableKey: executable ?? false});

  @visibleForTesting
  static ValueChanged<Map<String, Object?>>? onEvent;

  static Future<bool> supportsFile(File file) async {
    final input = await file.open();
    try {
      final header = await input.read(12);
      // 动画和其他格式直接沿用完整帧，避免复制快照及启动无用 worker。
      return (header.length >= 3 &&
              header[0] == 0xff &&
              header[1] == 0xd8 &&
              header[2] == 0xff) ||
          (header.length >= 8 &&
              header[0] == 0x89 &&
              header[1] == 0x50 &&
              header[2] == 0x4e &&
              header[3] == 0x47 &&
              header[4] == 13 &&
              header[5] == 10 &&
              header[6] == 26 &&
              header[7] == 10) ||
          (header.length == 12 &&
              ascii.decode(header.sublist(0, 4), allowInvalid: true) ==
                  'RIFF' &&
              ascii.decode(header.sublist(8, 12), allowInvalid: true) ==
                  'WEBP');
    } finally {
      await input.close();
    }
  }

  static Future<NativeWorkerDecoder> open(ImageSourceLease lease) async {
    final worker = executable;
    if (worker == null) throw UnsupportedError('当前平台没有区域解码后端');
    final source = lease.retain();
    Process? process;
    _WorkerOutput? lines;
    try {
      process = await Process.start(worker, [source.file.path, '-', 'pipe']);
      lines = _WorkerOutput(process.stdout);
      unawaited(process.stderr.drain<void>());
      final metadata = (jsonDecode(
        await lines.line().timeout(const Duration(seconds: 15)),
      ) as Map).cast<String, dynamic>();
      if (metadata['unsupported'] == true) {
        throw UnsupportedError('系统 WIC 没有此格式的解码器');
      }
      if (metadata['ready'] != true ||
          metadata['width'] is! int ||
          metadata['height'] is! int ||
          metadata['frames'] is! int ||
          (metadata['width'] as int) <= 0 ||
          (metadata['height'] as int) <= 0) {
        throw StateError('区域解码元信息无效');
      }
      return NativeWorkerDecoder._(process, lines, source, metadata);
    } catch (_) {
      process?.kill();
      if (process != null) await process.exitCode;
      await lines?.cancel();
      await source.dispose();
      rethrow;
    }
  }

  final Process process;
  final _WorkerOutput _lines;
  final ImageSourceLease _source;
  final Map<String, dynamic> metadata;
  int _index = 0;
  bool _disposed = false;
  final _closed = Completer<void>();

  void _report(String event, [Map<String, Object?> details = const {}]) {
    Diagnostics.instance.gauge('imageRegionWorkers', nativeWorkers.length);
    onEvent?.call({'event': event, 'pid': process.pid, ...details});
  }

  @override
  Future<void> get drained => _closed.future;
  @override
  Size get sourceSize => Size(
    (metadata['width'] as int).toDouble(),
    (metadata['height'] as int).toDouble(),
  );
  @override
  int get frameCount => metadata['frames'] as int;
  @override
  bool get hasBoundedBase =>
      metadata['orientation'] == 1 && metadata['supported'] == true;
  @override
  bool get hasIndependentRegions => hasBoundedBase;

  Future<RegionImage> _decode(int level, Rect read, Rect core) async {
    try {
      return await _decodePixels(level, read, core);
    } catch (error, stack) {
      // 超时和错误不能提前归还名额：进程退出才代表真实原生工作结束。
      dispose();
      try {
        await drained;
      } catch (_) {
        /* 保留原始解码错误。 */
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<RegionImage> _decodePixels(int level, Rect read, Rect core) async {
    if (_disposed) throw StateError('区域解码进程已关闭');
    if (level < 0 ||
        level > 16 ||
        read.isEmpty ||
        ![
          read.left,
          read.top,
          read.right,
          read.bottom,
        ].every((value) => value.isFinite)) {
      throw ArgumentError('无效的区域解码请求');
    }
    final factor = 1 << level;
    final width = (read.width / factor).ceil();
    final height = (read.height / factor).ceil();
    final bytes = width * height * 4;
    if (bytes > 40 << 20) throw StateError('区域解码输出超限');
    final index = ++_index;
    process.stdin.writeln(
      '$level ${(read.left / factor).floor()} ${(read.top / factor).floor()} $width $height $index',
    );
    await process.stdin.flush();
    final info = (jsonDecode(
      await _lines.line().timeout(const Duration(seconds: 30)),
    ) as Map).cast<String, dynamic>();
    if (info['index'] != index ||
        info['guards'] != true ||
        info['width'] != width ||
        info['height'] != height ||
        info['bytes'] != bytes) {
      throw StateError('区域解码输出不符合请求');
    }
    // 不生成 raw 临时文件，避免系统文件缓存持有额外像素。
    final data = await _lines
        .pixels(bytes)
        .timeout(const Duration(seconds: 30));
    _report('decode', {'level': level, ...info});
    final buffer = await ui.ImmutableBuffer.fromUint8List(data);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return RegionImage(image: frame.image, sourceRect: read, core: core);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  @override
  Future<RegionImage> decodeBase(int maximumPixels) {
    if (maximumPixels <= 0) {
      throw ArgumentError.value(maximumPixels, 'maximumPixels');
    }
    var level = 0;
    while ((sourceSize.width / (1 << level)).ceil() *
            (sourceSize.height / (1 << level)).ceil() >
        maximumPixels) {
      level++;
    }
    return _decode(level, Offset.zero & sourceSize, Offset.zero & sourceSize);
  }

  @override
  Future<RegionImage> decodeRegion(RegionRequest request) {
    if (metadata['webp'] == true && request.level > 0 && request.level <= 16) {
      final factor = 1 << request.level;
      final globalBytes =
          (sourceSize.width / factor).ceil() *
          (sourceSize.height / factor).ceil() *
          4;
      // WebP 缩放须对齐全局相位；小视口也可能要求超容量的全局中间层。
      // 在提交像素请求前报告能力边界，让内容会话排空后走完整帧。
      if (globalBytes > 40 << 20) {
        return Future.error(UnsupportedError('WebP 全局缩放层超过区域后端容量'));
      }
    }
    return _decode(request.level, request.read, request.core);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_close());
  }

  Future<void> _close() async {
    Object? failure;
    StackTrace? failureStack;
    try {
      process.stdin.writeln('close');
      await process.stdin.close();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill();
          return process.exitCode;
        },
      );
      if (exit != 0) throw StateError('区域解码进程退出异常：$exit');
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      try {
        process.kill();
        await process.exitCode;
        await _lines.cancel();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      try {
        await _source.dispose();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      nativeWorkers.remove(this);
      _report(failure == null ? 'close' : 'closeError');
      if (failure == null) {
        _closed.complete();
      } else {
        _closed.completeError(failure, failureStack);
      }
    }
  }
}
