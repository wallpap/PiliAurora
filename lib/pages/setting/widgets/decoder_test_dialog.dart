import 'dart:async';
import 'dart:io' show Platform, Process, ProcessInfo;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 解码器兼容性测试入口。
///
/// 测试沿用播放器的 media_kit 配置。每个格式和后端组合都会创建独立播放器，
/// 并单独采集一段性能数据。
class DecoderTestDialog extends StatefulWidget {
  const DecoderTestDialog({super.key});

  @override
  State<DecoderTestDialog> createState() => _DecoderTestDialogState();
}

class _DecoderTestDialogState extends State<DecoderTestDialog> {
  static const _sampleBvid = 'BV1fK4y1t7hj';
  static const _sampleCid = 196018899;
  static const _startupTimeout = Duration(seconds: 10);
  static const _measureLength = Duration(seconds: 3);
  static const _sampleTimeout = Duration(seconds: 15);

  final Map<String, _DecoderResult> _results = {};
  final Set<int> _selectedCodecs = {};
  final Set<String> _selectedDecoders = {};
  late final List<HwDecType> _decoders = _availableDecoders;

  List<VideoItem> _codecs = const [];
  Player? _activePlayer;
  VideoController? _activeVideoController;
  String? _error;
  bool _loading = true;
  bool _testing = false;
  int _testGeneration = 0;
  int _completedTests = 0;
  int _totalTests = 0;

  List<HwDecType> get _availableDecoders {
    final values = <HwDecType>[
      HwDecType.no,
      HwDecType.auto,
      HwDecType.autoSafe,
      if (Platform.isAndroid) ...[
        HwDecType.mediacodec,
        HwDecType.mediacodecCopy,
      ] else if (Platform.isWindows) ...[
        HwDecType.d3d12va,
        HwDecType.d3d12vaCopy,
        HwDecType.d3d11va,
        HwDecType.d3d11vaCopy,
        HwDecType.dxva2,
        HwDecType.dxva2Copy,
        HwDecType.nvdec,
        HwDecType.nvdecCopy,
        HwDecType.qsv,
        HwDecType.qsvCopy,
        HwDecType.amf,
        HwDecType.amfCopy,
        HwDecType.vulkan,
        HwDecType.vulkanCopy,
      ],
      HwDecType.autoCopy,
    ];
    for (final configured in Pref.hardwareDecoding.split(',')) {
      final decoder = HwDecType.values
          .where((type) => type.hwdec == configured.trim())
          .firstOrNull;
      if (decoder != null && !values.contains(decoder)) values.add(decoder);
    }
    return values;
  }

  @override
  void initState() {
    super.initState();
    final configured = Pref.hardwareDecoding
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    _selectedDecoders.addAll({
      HwDecType.no.hwdec,
      ..._decoders
          .where((decoder) => configured.contains(decoder.hwdec))
          .map((decoder) => decoder.hwdec),
    });
    unawaited(_loadSample());
  }

  @override
  void dispose() {
    _testGeneration++;
    final player = _activePlayer;
    _activePlayer = null;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _loadSample() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final result = await VideoHttp.videoUrl(
        cid: _sampleCid,
        bvid: _sampleBvid,
        qn: VideoQuality.high1080.code,
        tryLook: false,
        videoType: VideoType.ugc,
      ).timeout(_sampleTimeout);
      final videos = result.dataOrNull?.dash?.video ?? const <VideoItem>[];
      final codecs = <int, VideoItem>{};
      for (final video in videos) {
        if ([7, 12, 13].contains(video.codecid) && video.playUrls.isNotEmpty) {
          codecs.putIfAbsent(video.codecid!, () => video);
        }
      }
      if (!mounted) return;
      setState(() {
        _codecs = codecs.values.toList();
        if (_codecs.isNotEmpty) {
          _selectedCodecs
            ..clear()
            ..add(_codecs.first.codecid!);
        }
        _loading = false;
        if (_codecs.isEmpty) _error = '公开视频未提供可测试的 AVC、HEVC 或 AV1 格式';
      });
    } catch (error) {
      if (kDebugMode) debugPrint('Decoder test sample load failed: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法获取测试视频，请检查网络后重试';
      });
    }
  }

  String _codecName(VideoItem item) => switch (item.codecid) {
    7 => 'AVC',
    12 => 'HEVC',
    13 => 'AV1',
    _ => item.codecs ?? '未知格式',
  };

  String _decoderName(String decoder) {
    if (decoder.isEmpty || decoder == 'no') return '软件解码';
    return HwDecType.values
            .where((type) => type.hwdec == decoder)
            .map((type) => type.desc.split('：').first)
            .firstOrNull ??
        decoder;
  }

  Future<void> _runTests() async {
    if (_testing || _selectedCodecs.isEmpty || _selectedDecoders.isEmpty) {
      return;
    }
    final codecs = _codecs
        .where((codec) => _selectedCodecs.contains(codec.codecid))
        .toList();
    final decoders = _decoders
        .where((decoder) => _selectedDecoders.contains(decoder.hwdec))
        .toList();
    if (codecs.isEmpty || decoders.isEmpty) return;

    final generation = ++_testGeneration;
    _totalTests = codecs.length * decoders.length;
    _completedTests = 0;
    setState(() {
      _testing = true;
      _error = null;
      _results.clear();
    });

    for (final codec in codecs) {
      for (final decoder in decoders) {
        if (!mounted || generation != _testGeneration) break;
        final key = _resultKey(codec, decoder);
        setState(() => _results[key] = const _DecoderResult.running());
        final result = await _testDecoder(codec, decoder);
        if (!mounted || generation != _testGeneration) break;
        setState(() {
          _results[key] = result;
          _completedTests++;
        });
      }
    }

    if (mounted && generation == _testGeneration) {
      setState(() => _testing = false);
    }
  }

  String _resultKey(VideoItem codec, HwDecType decoder) =>
      '${codec.codecid}:${decoder.hwdec}';

  Future<void> _stopTests() async {
    if (!_testing) return;
    _testGeneration++;
    _testing = false;
    final player = _activePlayer;
    _activePlayer = null;
    if (player != null) await player.dispose();
    if (mounted) setState(() {});
  }

  Future<_DecoderResult> _testDecoder(
    VideoItem codec,
    HwDecType decoder,
  ) async {
    Player? player;
    StreamSubscription<String>? errorSubscription;
    String? playbackError;
    final monitor = _PerformanceMonitor();
    try {
      monitor.start();
      player = await Player.create(
        configuration: const PlayerConfiguration(
          logLevel: kDebugMode ? .warn : .error,
          options: {'audio': 'no', 'video-sync': 'audio'},
        ),
      );
      _activePlayer = player;
      final errors = Completer<String>();
      errorSubscription = player.stream.error.listen((message) {
        if (!errors.isCompleted) errors.complete(message);
      });
      final videoController = await VideoController.create(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: decoder != HwDecType.no,
          hwdec: decoder.hwdec,
        ),
      );
      _activeVideoController = videoController;
      if (mounted) setState(() {});
      final url = codec.playUrls.firstOrNull;
      if (url == null || url.isEmpty) throw StateError('测试视频地址为空');
      await player.open(Media(url), play: true).timeout(_startupTimeout);

      await Future.any([
        player.stream.position
            .firstWhere((position) => position >= const Duration(seconds: 1))
            .then((_) {}),
        errors.future.then((message) => throw StateError(message)),
        Future<void>.delayed(_startupTimeout).then(
          (_) => throw TimeoutException('视频无法开始播放'),
        ),
      ]);
      final startPosition = player.state.position;
      await Future.any([
        Future<void>.delayed(_measureLength),
        errors.future.then((message) => playbackError = message),
      ]);
      if (playbackError != null) throw StateError(playbackError!);

      final position = player.state.position;
      final size = '${player.state.width}x${player.state.height}';
      final activeDecoder = player.getProperty('hwdec-current').trim();
      final played = position - startPosition;
      if (played < const Duration(seconds: 2)) {
        throw StateError('视频未能持续播放');
      }
      return _DecoderResult.success(
        decoder: _decoderName(activeDecoder),
        size: size,
        speed: played.inMilliseconds / _measureLength.inMilliseconds,
        performance: await monitor.stop(),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Decoder test ${decoder.hwdec} failed: $error');
      }
      final message = error.toString().replaceFirst('Bad state: ', '');
      return _DecoderResult.failure(
        message.length > 68 ? '初始化或播放失败' : message,
        performance: await monitor.stop(),
      );
    } finally {
      await errorSubscription?.cancel();
      if (identical(_activePlayer, player)) {
        _activePlayer = null;
        await player?.dispose();
      }
      if (mounted) {
        setState(() => _activeVideoController = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final inset = size.width < 520 ? 12.0 : 24.0;
    final dialogWidth = math.min(760.0, size.width - inset * 2);
    final dialogHeight = math.min(620.0, math.max(180.0, size.height - 220));
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(horizontal: inset, vertical: 24),
      constraints: BoxConstraints(
        minWidth: math.min(280.0, dialogWidth),
        maxWidth: dialogWidth,
      ),
      title: Row(
        children: [
          const Expanded(child: Text('解码器测试')),
          if (_testing)
            Text(
              '$_completedTests/$_totalTests',
              style: theme.textTheme.labelMedium,
            ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: _buildContent(theme),
      ),
      actions: [
        TextButton(
          onPressed: _testing ? _stopTests : () => Navigator.of(context).pop(),
          child: Text(_testing ? '停止测试' : '关闭'),
        ),
        FilledButton.icon(
          onPressed: _loading || _error != null || _testing ? null : _runTests,
          icon: _testing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(_testing ? '正在测试' : '开始测试选中项'),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在获取测试视频…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _loadSample,
              icon: const Icon(Icons.refresh),
              label: const Text('重新获取'),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        Text('解码格式', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '选择要验证的视频编码格式，可多选。每个格式会分别使用下方选中的硬解模式播放。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _SelectionWrap<VideoItem, int>(
          values: _codecs,
          selected: _selectedCodecs,
          valueOf: (codec) => codec.codecid!,
          labelOf: _codecName,
          enabled: !_testing,
          onChanged: (value, selected) {
            setState(() {
              if (selected) {
                _selectedCodecs.add(value);
              } else {
                _selectedCodecs.remove(value);
              }
              _results.clear();
            });
          },
        ),
        const SizedBox(height: 20),
        Text('硬解模式', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '选择硬解模式进行实际播放测试。软件解码可作为 CPU 基线，GPU 指标在系统不支持时显示为 --。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _SelectionWrap<HwDecType, String>(
          values: _decoders,
          selected: _selectedDecoders,
          valueOf: (decoder) => decoder.hwdec,
          labelOf: (decoder) => decoder.desc.split('：').first,
          enabled: !_testing,
          onChanged: (value, selected) {
            setState(() {
              if (selected) {
                _selectedDecoders.add(value);
              } else {
                _selectedDecoders.remove(value);
              }
              _results.clear();
            });
          },
        ),
        const SizedBox(height: 16),
        if (_activeVideoController case final controller?) ...[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Video(controller: controller),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_results.isNotEmpty) ...[
          Text('测试结果', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'CPU 为系统占用，内存为 PiliAurora 进程峰值，GPU 为系统引擎占用。数值越低通常越省资源。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final codec in _codecs)
            if (_selectedCodecs.contains(codec.codecid)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text(
                  _codecName(codec),
                  style: theme.textTheme.labelLarge,
                ),
              ),
              for (final decoder in _decoders)
                if (_selectedDecoders.contains(decoder.hwdec))
                  _DecoderResultTile(
                    decoder: decoder,
                    result: _results[_resultKey(codec, decoder)],
                  ),
            ],
        ],
      ],
    );
  }
}

class _SelectionWrap<T, V> extends StatelessWidget {
  final List<T> values;
  final Set<V> selected;
  final V Function(T value) valueOf;
  final String Function(T value) labelOf;
  final bool enabled;
  final void Function(V value, bool selected) onChanged;

  const _SelectionWrap({
    required this.values,
    required this.selected,
    required this.valueOf,
    required this.labelOf,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final value in values)
        FilterChip(
          label: Text(labelOf(value)),
          selected: selected.contains(valueOf(value)),
          onSelected: enabled
              ? (isSelected) => onChanged(valueOf(value), isSelected)
              : null,
        ),
    ],
  );
}

class _DecoderResult {
  final bool running;
  final bool passed;
  final String? decoder;
  final String? size;
  final double? speed;
  final String? error;
  final _PerformanceSummary? performance;

  const _DecoderResult._({
    this.running = false,
    this.passed = false,
    this.decoder,
    this.size,
    this.speed,
    this.error,
    this.performance,
  });

  const _DecoderResult.running() : this._(running: true);

  const _DecoderResult.success({
    required String decoder,
    required String size,
    required double speed,
    required _PerformanceSummary performance,
  }) : this._(
         passed: true,
         decoder: decoder,
         size: size,
         speed: speed,
         performance: performance,
       );

  const _DecoderResult.failure(
    String error, {
    required _PerformanceSummary performance,
  }) : this._(error: error, performance: performance);
}

class _DecoderResultTile extends StatelessWidget {
  final HwDecType decoder;
  final _DecoderResult? result;

  const _DecoderResultTile({required this.decoder, this.result});

  String _metric(double? value, String suffix) =>
      value == null ? '--' : '${value.toStringAsFixed(1)}$suffix';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (result) {
      null => '未测试',
      _ when result!.running => '测试中',
      _ when result!.passed =>
        '${result!.decoder} · ${result!.size} · ${result!.speed!.toStringAsFixed(1)}×实时',
      _ => result!.error ?? '不兼容',
    };
    final icon = switch (result) {
      null => Icons.circle_outlined,
      _ when result!.running => Icons.pending_outlined,
      _ when result!.passed => Icons.check_circle_outline,
      _ => Icons.error_outline,
    };
    final color = result == null || result!.running
        ? theme.colorScheme.outline
        : result!.passed
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final performance = result?.performance;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(decoder.desc.split('：').first),
      subtitle: Text(
        '$status\n'
        'CPU ${_metric(performance?.averageCpu, '%')}  ·  '
        '内存 ${_metric(performance?.peakMemoryMb, ' MB')}  ·  '
        'GPU ${_metric(performance?.averageGpu, '%')}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _PerformanceSummary {
  final double? averageCpu;
  final double? peakMemoryMb;
  final double? averageGpu;

  const _PerformanceSummary({
    required this.averageCpu,
    required this.peakMemoryMb,
    required this.averageGpu,
  });
}

class _PerformanceSample {
  final double? cpu;
  final double memoryMb;
  final double? gpu;

  const _PerformanceSample({this.cpu, required this.memoryMb, this.gpu});
}

class _PerformanceMonitor {
  static const _interval = Duration(milliseconds: 750);

  Timer? _timer;
  final List<_PerformanceSample> _samples = [];
  Future<void>? _pendingRead;

  void start() {
    _samples.clear();
    unawaited(_record());
    _timer = Timer.periodic(_interval, (_) => unawaited(_record()));
  }

  Future<_PerformanceSummary> stop() async {
    _timer?.cancel();
    _timer = null;
    await _record();
    final cpu = _samples
        .map((sample) => sample.cpu)
        .whereType<double>()
        .toList();
    final gpu = _samples
        .map((sample) => sample.gpu)
        .whereType<double>()
        .toList();
    final memory = _samples.map((sample) => sample.memoryMb).toList();
    return _PerformanceSummary(
      averageCpu: cpu.isEmpty ? null : cpu.reduce((a, b) => a + b) / cpu.length,
      peakMemoryMb: memory.isEmpty ? null : memory.reduce(math.max),
      averageGpu: gpu.isEmpty ? null : gpu.reduce((a, b) => a + b) / gpu.length,
    );
  }

  Future<void> _record() async {
    final pending = _pendingRead;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _recordInternal();
    _pendingRead = future;
    try {
      await future;
    } finally {
      if (identical(_pendingRead, future)) _pendingRead = null;
    }
  }

  Future<void> _recordInternal() async {
    try {
      final memoryMb = ProcessInfo.currentRss / (1024 * 1024);
      double? cpu;
      double? gpu;
      if (Platform.isWindows) {
        final values = await _readWindowsCounters();
        cpu = values.$1;
        gpu = values.$2;
      }
      _samples.add(_PerformanceSample(cpu: cpu, memoryMb: memoryMb, gpu: gpu));
    } catch (_) {
      // 播放器重启时计数器可能暂时不可用，但仍保留内存采样。
      _samples.add(
        _PerformanceSample(
          memoryMb: ProcessInfo.currentRss / (1024 * 1024),
        ),
      );
    }
  }

  Future<(double?, double?)> _readWindowsCounters() async {
    const script = r'''
$cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue).CounterSamples | Select-Object -First 1 -ExpandProperty CookedValue
$gpu = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples | Measure-Object -Property CookedValue -Maximum | Select-Object -ExpandProperty Maximum
"$cpu|$gpu"
''';
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
    ).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return (null, null);
    final output = result.stdout.toString().trim();
    final parts = output.split('|');
    if (parts.length < 2) return (null, null);
    return (double.tryParse(parts[0].trim()), double.tryParse(parts[1].trim()));
  }
}
