import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

import 'package:pili_aurora/pages/setting/decoder_test.dart';
import 'package:pili_aurora/pages/setting/decoder_test_process.dart';

export 'package:pili_aurora/pages/setting/decoder_test.dart'
    show configureDecoderTestMediaHeaders;

/// 解码器兼容性测试入口。
///
/// 每个组合沿用播放会话与平台输出，检查持续出画和实际解码后端。
class DecoderTestDialog extends StatefulWidget {
  const DecoderTestDialog({super.key, this.sampleLoader, this.sessionFactory});

  final Future<List<VideoItem>> Function()? sampleLoader;
  final DecoderTestSessionFactory? sessionFactory;

  @override
  State<DecoderTestDialog> createState() => _DecoderTestDialogState();
}

class _DecoderTestDialogState extends State<DecoderTestDialog> {
  static const _sampleBvid = 'BV1fK4y1t7hj';
  static const _sampleCid = 196018899;
  static const _sampleTimeout = Duration(seconds: 15);

  final Map<String, DecoderTestResult> _results = {};
  final Set<int> _selectedCodecs = {};
  final Set<String> _selectedDecoders = {};
  late final List<HwDecType> _decoders = _availableDecoders;

  List<VideoItem> _codecs = const [];
  DecoderTestSession? _activeSession;
  bool _stopping = false;
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
    final session = _activeSession;
    _activeSession = null;
    if (session != null) {
      unawaited(
        session.dispose().catchError((Object error) {
          Diagnostics.instance.playerLog(
            DiagnosticLogLevel.error,
            'decoderTest',
            error,
          );
        }),
      );
    }
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
      final codecs = decoderTestSamples(videos);
      if (!mounted) return;
      setState(() {
        _codecs = codecs;
        if (_codecs.isNotEmpty) {
          _selectedCodecs
            ..clear()
            ..add(_codecs.first.codecid!);
        }
        _loading = false;
        if (_codecs.isEmpty) _error = '公开视频未提供可测试的 AVC、HEVC 或 AV1 格式';
      });
    } catch (error) {
      Diagnostics.instance.playerLog(
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
    if (!result.isSuccess) throw result;
    return result.dataOrNull?.dash?.video ?? const <VideoItem>[];
  }

  String _codecName(VideoItem item) => switch (item.codecid) {
    7 => 'AVC',
    12 => 'HEVC',
    13 => 'AV1',
    _ => item.codecs ?? '未知格式',
  };

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
    setState(() {
      _testing = true;
      _error = null;
      _results.clear();
      _totalTests = codecs.length * decoders.length;
      _completedTests = 0;
    });
    try {
      for (final codec in codecs) {
        for (final decoder in decoders) {
          if (!mounted || generation != _testGeneration) return;
          final key = _resultKey(codec, decoder);
          DecoderTestSession? session;
          setState(() => _results[key] = const DecoderTestResult.running());
          try {
            session = (widget.sessionFactory ?? createDecoderTestSession)(
              decoder,
              codec,
            );
            _activeSession = session;
            setState(() {});
            final result = await session.run();
            if (!mounted || generation != _testGeneration) return;
            setState(() {
              _results[key] = result;
              _completedTests++;
            });
          } catch (error) {
            if (!mounted || generation != _testGeneration) return;
            setState(() {
              _results[key] = DecoderTestResult.failure(
                formatDecoderTestError(error),
              );
              _completedTests++;
            });
          } finally {
            // dispose 必须代表真正的原生释放；停止与本轮收尾共用同一个 Future。
            await session?.dispose();
            if (identical(_activeSession, session)) {
              _activeSession = null;
              if (mounted) setState(() {});
            }
          }
        }
      }
    } catch (error) {
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.error,
        'decoderTest',
        error,
      );
      if (mounted && generation == _testGeneration) {
        setState(() => _error = formatDecoderTestError(error));
      }
    } finally {
      if (mounted && generation == _testGeneration) {
        setState(() => _testing = false);
      }
    }
  }

  String _resultKey(VideoItem codec, HwDecType decoder) =>
      '${codec.codecid}:${decoder.hwdec}';

  Future<void> _stopTests() async {
    if (!_testing || _stopping) return;
    final session = _activeSession;
    setState(() {
      _testGeneration++;
      _stopping = true;
      _activeSession = null;
      for (final key in _results.keys.toList()) {
        if (_results[key]!.running) {
          _results[key] = const DecoderTestResult.cancelled();
        }
      }
    });
    try {
      await session?.dispose();
    } catch (error) {
      if (mounted) setState(() => _error = formatDecoderTestError(error));
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _stopping = false;
        });
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
        child: Column(
          children: [
            if (_activeSession is ProcessDecoderTestSession)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('正在独立窗口中测试，完成后自动关闭。'),
              )
            else if (_activeSession case final session?)
              ValueListenableBuilder<VideoController?>(
                valueListenable: session.videoController,
                builder: (_, controller, _) => controller == null
                    ? const SizedBox.shrink()
                    : SizedBox(
                        height: math.min(140, dialogHeight * 0.32),
                        child: Video(controller: controller),
                      ),
              ),
            Expanded(child: _buildContent(theme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _stopping
              ? null
              : _testing
              ? _stopTests
              : () => Navigator.of(context).pop(),
          child: Text(
            _stopping
                ? '正在停止…'
                : _testing
                ? '停止测试'
                : '关闭',
          ),
        ),
        FilledButton.icon(
          onPressed:
              _loading ||
                  _error != null ||
                  _testing ||
                  _selectedCodecs.isEmpty ||
                  _selectedDecoders.isEmpty
              ? null
              : _runTests,
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
          '选择要验证的模式。软件解码仅切换解码器，使用相同的视频输出；当前未提供 GPU 用量。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _SelectionWrap<HwDecType, String>(
          values: _decoders,
          selected: _selectedDecoders,
          valueOf: (decoder) => decoder.hwdec,
          labelOf: decoderTestLabel,
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
        if (_results.isNotEmpty) ...[
          Text('测试结果', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '结果验证本次播放与出画，颜色和观感请结合预览检查。CPU 为测试所在进程占全机的比例，内存为本轮工作集峰值；-- 表示指标不可用。',
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

class _DecoderResultTile extends StatelessWidget {
  final HwDecType decoder;
  final DecoderTestResult? result;

  const _DecoderResultTile({required this.decoder, this.result});

  String _metric(double? value, String suffix) =>
      value == null ? '--' : '${value.toStringAsFixed(1)}$suffix';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (result) {
      null => '未测试',
      _ when result!.running => '测试中',
      _ when result!.cancelled => '已停止',
      _ when result!.passed =>
        '${result!.fallback ? "回退后可播放" : "兼容"} · ${result!.decoder} · ${result!.size} · 播放进度比 ${result!.speed!.toStringAsFixed(1)}×',
      _ => result!.error ?? '不兼容',
    };
    final icon = switch (result) {
      null => Icons.circle_outlined,
      _ when result!.running => Icons.pending_outlined,
      _ when result!.cancelled => Icons.stop_circle_outlined,
      _ when result!.fallback => Icons.warning_amber_outlined,
      _ when result!.passed => Icons.check_circle_outline,
      _ => Icons.error_outline,
    };
    final color = result == null || result!.running || result!.cancelled
        ? theme.colorScheme.outline
        : result!.fallback
        ? theme.colorScheme.tertiary
        : result!.passed
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final performance = result?.performance;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(decoderTestLabel(decoder)),
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
