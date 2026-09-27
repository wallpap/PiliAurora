import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:archive/archive_io.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

enum DiagnosticLogLevel {
  trace('跟踪', '最详细的事件与耗时'),
  debug('调试', '请求、缓存与播放过程'),
  info('信息', '主要状态变化'),
  warning('警告', '异常情况与错误（默认）'),
  error('错误', '仅记录失败'),
  off('关闭', '停止运行日志与异常记录');

  const DiagnosticLogLevel(this.label, this.description);
  final String label;
  final String description;

  static DiagnosticLogLevel parse(String? value) =>
      values.where((level) => level.name == value).firstOrNull ?? warning;
}

class Diagnostics extends ChangeNotifier {
  Diagnostics({this.processReader});

  static final instance = Diagnostics();
  static const intervals = [250, 1000, 5000];
  final Map<String, Object?> Function()? processReader;
  final _processMetrics = ProcessMetrics();
  final _sources = <String, Map<String, Object?> Function()>{};
  final _operations = <String, _OperationStats>{};
  final _gauges = <String, num>{};
  final _recent = Queue<Map<String, Object?>>();
  final _frames = _FrameStats();
  final _elapsed = Stopwatch();
  DiagnosticRecordStore? _logs;
  DiagnosticRecordStore? _trace;
  Timer? _timer;
  Timer? _notification;
  bool _tracing = false;
  DiagnosticLogLevel _level = DiagnosticLogLevel.warning;
  int _intervalMs = 1000;
  int _sequence = 0;
  String _route = '/';
  String? _session;
  Map<String, Object?>? latest;
  Future<void> Function(Map<String, Object?>)? _saveSettings;

  bool get tracing => _tracing;
  DiagnosticLogLevel get level => _level;
  int get intervalMs => _intervalMs;
  String? get session => _session;
  List<Map<String, Object?>> get recentLogs =>
      _recent.toList().reversed.toList();
  int get droppedRecords => (_logs?.dropped ?? 0) + (_trace?.dropped ?? 0);
  String? get storageError => _logs?.lastError ?? _trace?.lastError;

  Future<void> initialize({
    required Directory directory,
    DiagnosticLogLevel level = DiagnosticLogLevel.warning,
    bool tracing = false,
    int intervalMs = 1000,
    Future<void> Function(Map<String, Object?>)? saveSettings,
  }) async {
    _logs = DiagnosticRecordStore(File('${directory.path}/runtime.jsonl'));
    _trace = DiagnosticRecordStore(
      File('${directory.path}/performance.jsonl'),
      maxBytes: 8 << 20,
    );
    _saveSettings = saveSettings;
    _level = level;
    _intervalMs = intervals.contains(intervalMs) ? intervalMs : 1000;
    await _loadHistory();
    if (tracing) _start();
  }

  Future<void> _loadHistory() async {
    try {
      final files = await _logs!.files();
      for (final file in files.reversed) {
        // 每个轮转文件仅扫描末尾，避免诊断页面加载完整日志到内存。
        final length = file.lengthSync();
        final offset = length > 262144 ? length - 262144 : 0;
        var skipPartialLine = offset > 0;
        await for (final line
            in file
                .openRead(offset)
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())) {
          if (skipPartialLine) {
            skipPartialLine = false;
            continue;
          }
          try {
            final record = Map<String, Object?>.from(
              DiagnosticRedactor.clean(jsonDecode(line)) as Map,
            );
            _recent.add(record);
            while (_recent.length > 200) {
              _recent.removeFirst();
            }
          } catch (_) {
            /* 忽略中断写入留下的不完整行。 */
          }
        }
      }
    } catch (_) {
      /* 日志读取失败不影响应用启动。 */
    }
  }

  Future<void> configure({
    DiagnosticLogLevel? level,
    bool? tracing,
    int? intervalMs,
  }) async {
    if (level != null) _level = level;
    if (intervalMs != null && intervals.contains(intervalMs)) {
      _intervalMs = intervalMs;
    }
    if (tracing == false && _tracing) _stop();
    if (tracing == true && !_tracing) _start();
    if (_tracing && intervalMs != null) {
      _timer?.cancel();
      _timer = Timer.periodic(
        Duration(milliseconds: _intervalMs),
        (_) => capture(),
      );
    }
    notifyListeners();
    await _saveSettings?.call({
      'level': _level.name,
      'tracing': _tracing,
      'intervalMs': _intervalMs,
    });
  }

  bool accepts(DiagnosticLogLevel level) =>
      _level != DiagnosticLogLevel.off && level.index >= _level.index;

  void log(
    DiagnosticLogLevel level,
    String category,
    Object? message, {
    Object? details,
    StackTrace? stack,
  }) {
    if (!accepts(level)) return;
    final record = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'level': level.name,
      'category': category,
      'message': DiagnosticRedactor.text(message),
      if (details != null) 'details': DiagnosticRedactor.clean(details),
      if (stack != null) 'stack': DiagnosticRedactor.text(stack),
      if (_tracing) 'session': _session,
    };
    _recent.add(record);
    while (_recent.length > 200) {
      _recent.removeFirst();
    }
    _logs?.add(record);
    _notifySoon();
  }

  VoidCallback register(String name, Map<String, Object?> Function() reader) {
    _sources[name] = reader;
    return () {
      if (identical(_sources[name], reader)) _sources.remove(name);
    };
  }

  void gauge(String name, num value) => _gauges[name] = value;

  TraceOperation? begin(
    String category,
    String action, {
    Map<String, Object?>? details,
  }) {
    if (!_tracing && !accepts(DiagnosticLogLevel.debug)) return null;
    final stats = _operations.putIfAbsent(category, _OperationStats.new);
    stats.active++;
    return TraceOperation._(this, category, action, details, stats);
  }

  void routeChanged(String? name) {
    _route = DiagnosticRedactor.text((name ?? '/').split('?').first);
    log(
      DiagnosticLogLevel.info,
      'navigation',
      '页面切换',
      details: {'route': _route},
    );
  }

  void _start() {
    _processMetrics.reset();
    _tracing = true;
    _session = DateTime.now().toUtc().toIso8601String();
    _sequence = 0;
    for (final stats in _operations.values) {
      stats.take();
    }
    _elapsed
      ..reset()
      ..start();
    _frames.take();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _trace?.add({
      'type': 'session',
      'session': _session,
      'platform': Platform.operatingSystem,
      'runtime': Platform.version.split(' ').first,
      'notes': 'CPU 为进程用量；图片字节为缓存账面值，不能与 RSS 相加。GPU、Dart 堆和各模块独占内存不可直接测量。HTTP 字节仅为服务端声明长度。',
    });
    _timer = Timer.periodic(
      Duration(milliseconds: _intervalMs),
      (_) => capture(),
    );
    capture();
  }

  void _onFrames(List<FrameTiming> timings) {
    if (!_tracing) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.firstOrNull?.display.refreshRate ?? 60;
    _frames.add(timings, 1000000 / (rate > 0 ? rate : 60));
  }

  void capture() {
    if (!_tracing) return;
    final cache = PaintingBinding.instance.imageCache;
    final sources = <String, Object?>{};
    for (final entry in _sources.entries.toList()) {
      try {
        sources[entry.key] = entry.value();
      } catch (_) {
        sources[entry.key] = {'available': false};
      }
    }
    Map<String, Object?> process;
    try {
      process = (processReader ?? _processMetrics.sample)();
    } catch (_) {
      process = {'available': false};
    }
    latest = {
      'type': 'sample',
      'session': _session,
      'sequence': ++_sequence,
      'time': DateTime.now().toUtc().toIso8601String(),
      'elapsedMs': _elapsed.elapsedMilliseconds,
      'route': _route,
      'process': process,
      'frames': _frames.take(),
      'images': {
        'cacheBytes': cache.currentSizeBytes,
        'cacheEntries': cache.currentSize,
        'liveImages': cache.liveImageCount,
        'pendingImages': cache.pendingImageCount,
        'limitBytes': cache.maximumSizeBytes,
      },
      'operations': {
        for (final entry in _operations.entries) entry.key: entry.value.take(),
      },
      'gauges': Map<String, num>.of(_gauges),
      'sources': sources,
      'diagnostics': {
        'droppedRecords': droppedRecords,
        'storageError': storageError,
      },
    };
    latest = Map<String, Object?>.from(DiagnosticRedactor.clean(latest) as Map);
    _trace?.add(latest!);
    _notifySoon();
  }

  void _stop() {
    capture();
    _tracing = false;
    _timer?.cancel();
    _timer = null;
    _elapsed.stop();
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    _trace?.add({
      'type': 'stop',
      'session': _session,
      'time': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _notifySoon() {
    _notification ??= Timer(const Duration(milliseconds: 250), () {
      _notification = null;
      notifyListeners();
    });
  }

  Future<List<File>> files() async => [
    ...?await _logs?.files(),
    ...?await _trace?.files(),
  ];
  Future<void> flush() async {
    await _logs?.flush();
    await _trace?.flush();
  }

  Future<void> clear() async {
    if (_tracing) await configure(tracing: false);
    await _logs?.clear();
    await _trace?.clear();
    _recent.clear();
    latest = null;
    notifyListeners();
  }

  /// 文件快照和压缩都使用本地文件，压缩移到后台 isolate。
  Future<File> exportArchive() async {
    final directory = await Directory.systemTemp.createTemp(
      'pili-diagnostics-',
    );
    try {
      final paths = [
        ...?await _logs?.snapshot(directory),
        ...?await _trace?.snapshot(directory),
      ];
      final manifest = File('${directory.path}/manifest.json');
      await manifest.writeAsString(
        jsonEncode({
          'schema': 1,
          'platform': Platform.operatingSystem,
          'created': DateTime.now().toUtc().toIso8601String(),
          'level': _level.name,
          'intervalMs': _intervalMs,
          'droppedRecords': droppedRecords,
          'app': DiagnosticRedactor.clean(_sources['app']?.call()),
          'notes': '每条 sample 为一个采样周期。RSS/私有提交/缓存值不可相加；null 表示未提供。无 GPU、Dart 堆和各模块独占内存数据。',
        }),
      );
      paths.add(manifest.path);
      final output = '${directory.path}/diagnostics.zip';
      await compute(_zip, (paths, output));
      return File(output);
    } catch (_) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // 清理失败不覆盖真正的导出错误。
      }
      rethrow;
    }
  }

  static Future<void> _zip((List<String>, String) args) async {
    final encoder = ZipFileEncoder()..create(args.$2);
    try {
      for (final path in args.$1) {
        await encoder.addFile(File(path));
      }
    } finally {
      await encoder.close();
    }
  }

  String snapshotText() =>
      const JsonEncoder.withIndent('  ').convert(latest ?? {});

  @override
  void dispose() {
    if (_tracing) _stop();
    _notification?.cancel();
    super.dispose();
  }
}

class TraceOperation {
  TraceOperation._(
    this._owner,
    this._category,
    this._action,
    this._details,
    this._stats,
  );
  final Diagnostics _owner;
  final String _category;
  final String _action;
  final Map<String, Object?>? _details;
  final _OperationStats _stats;
  final _watch = Stopwatch()..start();
  bool _done = false;

  void finish({Object? error, Map<String, Object?>? details}) {
    if (_done) return;
    _done = true;
    final milliseconds = _watch.elapsedMicroseconds / 1000;
    _stats
      ..active -= 1
      ..completed += 1
      ..totalMs += milliseconds;
    if (milliseconds > _stats.maxMs) _stats.maxMs = milliseconds;
    if (error != null) _stats.errors++;
    _owner.log(
      error == null ? DiagnosticLogLevel.debug : DiagnosticLogLevel.error,
      _category,
      _action,
      details: {
        ...?_details,
        ...?details,
        'durationMs': milliseconds,
        'error': ?error,
      },
    );
  }
}

class _OperationStats {
  int active = 0, completed = 0, errors = 0;
  double totalMs = 0, maxMs = 0;
  Map<String, Object?> take() {
    final result = <String, Object?>{
      'active': active,
      'completed': completed,
      'errors': errors,
      'averageMs': completed == 0 ? null : totalMs / completed,
      'maxMs': maxMs,
    };
    completed = errors = 0;
    totalMs = maxMs = 0;
    return result;
  }
}

class _FrameStats {
  int count = 0, slow = 0;
  double build = 0, raster = 0, maxBuild = 0, maxRaster = 0;
  void add(List<FrameTiming> timings, double budgetUs) {
    for (final frame in timings) {
      count++;
      final b = frame.buildDuration.inMicroseconds / 1000;
      final r = frame.rasterDuration.inMicroseconds / 1000;
      build += b;
      raster += r;
      if (b > maxBuild) maxBuild = b;
      if (r > maxRaster) maxRaster = r;
      if (frame.buildDuration.inMicroseconds > budgetUs ||
          frame.rasterDuration.inMicroseconds > budgetUs) {
        slow++;
      }
    }
  }

  Map<String, Object?> take() {
    final result = <String, Object?>{
      'count': count,
      'slowFrames': slow,
      'averageBuildMs': count == 0 ? null : build / count,
      'averageRasterMs': count == 0 ? null : raster / count,
      'maxBuildMs': maxBuild,
      'maxRasterMs': maxRaster,
    };
    count = slow = 0;
    build = raster = maxBuild = maxRaster = 0;
    return result;
  }
}

class DiagnosticRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      Diagnostics.instance.routeChanged(route.settings.name);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      Diagnostics.instance.routeChanged(previousRoute?.settings.name);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      Diagnostics.instance.routeChanged(newRoute?.settings.name);
}
