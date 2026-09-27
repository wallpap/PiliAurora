import 'dart:async';
import 'dart:io' show Platform;

import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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

  final Map<String, _DecoderResult> _results = {};
  late final List<HwDecType> _decoders = _availableDecoders;
  List<VideoItem> _codecs = const [];
  VideoItem? _selectedCodec;
  Player? _activePlayer;
  VideoController? _activeVideoController;
  String? _error;
  bool _loading = true;
  bool _testing = false;
  int _testGeneration = 0;

  List<HwDecType> get _availableDecoders => [
    HwDecType.no,
    HwDecType.auto,
    if (Platform.isAndroid) ...[
      HwDecType.mediacodec,
      HwDecType.mediacodecCopy,
    ] else if (Platform.isWindows) ...[
      HwDecType.d3d12va,
      HwDecType.d3d11va,
      HwDecType.dxva2,
      HwDecType.nvdec,
      HwDecType.qsv,
      HwDecType.amf,
    ],
    HwDecType.autoCopy,
  ];

  @override
  void initState() {
    super.initState();
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
    try {
      final result = await VideoHttp.videoUrl(
        cid: _sampleCid,
        bvid: _sampleBvid,
        qn: VideoQuality.high1080.code,
        tryLook: false,
        videoType: VideoType.ugc,
      );
      final videos = result.dataOrNull?.dash?.video ?? const <VideoItem>[];
      final codecs = <int, VideoItem>{};
      for (final video in videos) {
        if ([7, 12, 13].contains(video.codecid)) {
          codecs.putIfAbsent(video.codecid!, () => video);
        }
      }
      if (!mounted) return;
      setState(() {
        _codecs = codecs.values.toList();
        _selectedCodec = _codecs.firstOrNull;
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

  Future<void> _runTests() async {
    final codec = _selectedCodec;
    if (codec == null || _testing) return;
    final generation = ++_testGeneration;
    setState(() {
      _testing = true;
      _error = null;
      _results.clear();
    });

    for (final decoder in _decoders) {
      if (!mounted || generation != _testGeneration) break;
      setState(() => _results[decoder.hwdec] = const _DecoderResult.running());
      final result = await _testDecoder(codec, decoder);
      if (!mounted || generation != _testGeneration) break;
      setState(() => _results[decoder.hwdec] = result);
    }

    if (mounted && generation == _testGeneration) {
      setState(() => _testing = false);
    }
  }

  Future<_DecoderResult> _testDecoder(
    VideoItem codec,
    HwDecType decoder,
  ) async {
    Player? player;
    StreamSubscription<String>? errorSubscription;
    String? playbackError;
    try {
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
      await player
          .open(Media(codec.playUrls.first), play: true)
          .timeout(_startupTimeout);

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
      final speed = played.inMilliseconds / _measureLength.inMilliseconds;
      return _DecoderResult.success(
        decoder: _decoderName(activeDecoder),
        size: size,
        speed: speed,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Decoder test ${decoder.hwdec} failed: $error');
      }
      final message = error.toString().replaceFirst('Bad state: ', '');
      return _DecoderResult.failure(message.length > 68 ? '初始化或播放失败' : message);
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

  String _decoderName(String decoder) {
    if (decoder.isEmpty || decoder == 'no') return '软件解码';
    return HwDecType.values
            .where((type) => type.hwdec == decoder)
            .map((type) => type.desc.split('：').first)
            .firstOrNull ??
        decoder;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('解码器测试'),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width * 0.78,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Text(_error!)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('视频格式', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: [
                      for (final codec in _codecs)
                        ButtonSegment(
                          value: codec.codecid!,
                          label: Text(_codecName(codec)),
                        ),
                    ],
                    selected: {_selectedCodec!.codecid!},
                    onSelectionChanged: _testing
                        ? null
                        : (selection) {
                            setState(() {
                              _selectedCodec = _codecs.firstWhere(
                                (codec) => codec.codecid == selection.first,
                              );
                              _results.clear();
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '逐项播放同一段约 3 秒的视频。结果反映当前设备对所选格式的实际表现。',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (_activeVideoController case final controller?) ...[
                    const SizedBox(height: 12),
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Video(controller: controller),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final decoder in _decoders)
                          _DecoderResultTile(
                            decoder: decoder,
                            result: _results[decoder.hwdec],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _loading || _error != null || _testing ? null : _runTests,
          icon: _testing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(_testing ? '正在测试' : '开始全部测试'),
        ),
      ],
    );
  }
}

class _DecoderResult {
  final bool running;
  final bool passed;
  final String? decoder;
  final String? size;
  final double? speed;
  final String? error;

  const _DecoderResult._({
    this.running = false,
    this.passed = false,
    this.decoder,
    this.size,
    this.speed,
    this.error,
  });

  const _DecoderResult.running() : this._(running: true);
  const _DecoderResult.success({
    required String decoder,
    required String size,
    required double speed,
  }) : this._(passed: true, decoder: decoder, size: size, speed: speed);
  const _DecoderResult.failure(String error)
    : this._(error: error, passed: false);
}

class _DecoderResultTile extends StatelessWidget {
  final HwDecType decoder;
  final _DecoderResult? result;

  const _DecoderResultTile({required this.decoder, this.result});

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
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(decoder.desc.split('：').first),
      subtitle: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }
}
