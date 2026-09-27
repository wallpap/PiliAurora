import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';

typedef DecoderMediaHeaderWriter = void Function({
  String? userAgent,
  String? referer,
});

/// 使用和普通播放器相同的媒体请求头，避免 CDN 将测试流拒绝为 403。
void configureDecoderTestMediaHeaders(DecoderMediaHeaderWriter write) {
  write(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
}

/// 解码器兼容性测试入口。
///
/// 测试沿用播放器的 media_kit 配置。每个格式和后端组合都会创建独立播放器，
/// 并单独采集一段性能数据。
class DecoderTestDialog extends StatefulWidget {
  const DecoderTestDialog({super.key, this.sampleLoader});

  final Future<List<VideoItem>> Function()? sampleLoader;

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
      final videos = await (widget.sampleLoader?.call() ?? _fetchSample())
          .timeout(_sampleTimeout);
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
      Diagnostics.instance.log(
        DiagnosticLogLevel.error,
        'decoderTest',
        '测试视频加载失败',
        details: {'error': error},
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法获取测试视频，请检查网络后重试';
      });
    }
  }

  Future<List<VideoItem>> _fetchSample() async {
    final result = await VideoHttp.videoUrl(
      cid: _sampleCid,
      bvid: _sampleBvid,
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    return result.dataOrNull?.dash?.video ?? const <VideoItem>[];
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
    PlayerDiagnostics? diagnostics;
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
      diagnostics = PlayerDiagnostics(
        player,
        extra: () => {
          'purpose': 'decoderTest',
          'requestedDecoder': decoder.hwdec,
        },
      );
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
      configureDecoderTestMediaHeaders(({
        String? userAgent,
        String? referer,
      }) {
        player!.setMediaHeader(userAgent: userAgent, referer: referer);
      });
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
      Diagnostics.instance.log(
        DiagnosticLogLevel.error,
        'decoderTest',
        error,
        details: {'decoder': decoder.hwdec, 'codec': codec.codecid},
      );
      final message = error.toString().replaceFirst('Bad state: ', '');
      return _DecoderResult.failure(
        message.length > 68 ? '初始化或播放失败' : message,
        performance: await monitor.stop(),
      );
    } finally {
      diagnostics?.dispose();
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
          '选择硬解模式进行实际播放测试。软件解码可作为 CPU 基线，当前未提供 GPU 用量。',
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
            'CPU 为 PiliAurora 进程占全机的比例，内存为本轮采样的进程工作集峰值。其他页面也会影响结果；-- 表示指标不可用。',
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
        '内存 ${_metric(performance?.peakMemoryMb, ' MiB')}  ·  '
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

class _PerformanceMonitor {
  static const _interval = Duration(milliseconds: 750);

  Timer? _timer;
  final _metrics = ProcessMetrics();
  double _cpuTotal = 0;
  int _cpuSamples = 0;
  double? _peakMemoryMb;

  void start() {
    _timer?.cancel();
    _metrics.reset();
    _cpuTotal = 0;
    _cpuSamples = 0;
    _peakMemoryMb = null;
    _record();
    _timer = Timer.periodic(_interval, (_) => _record());
  }

  Future<_PerformanceSummary> stop() async {
    _timer?.cancel();
    _timer = null;
    _record();
    return _PerformanceSummary(
      averageCpu: _cpuSamples == 0 ? null : _cpuTotal / _cpuSamples,
      peakMemoryMb: _peakMemoryMb,
      averageGpu: null,
    );
  }

  void _record() {
    final values = _metrics.sample();
    if (values['cpuPercentMachine'] case final num cpu) {
      _cpuTotal += cpu;
      _cpuSamples++;
    }
    if (values['rssBytes'] case final num bytes) {
      final memoryMb = bytes / 1048576;
      _peakMemoryMb = math.max(_peakMemoryMb ?? 0, memoryMb);
    }
  }
}
