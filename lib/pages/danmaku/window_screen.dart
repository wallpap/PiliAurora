import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:pili_aurora/pages/danmaku/frame_scheduler.dart';
import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

typedef DanmakuPrepareFrame<T> = void Function(
  DanmakuWindowRenderer<T>,
  int mediaUs, {
  required double effectiveRate,
});

/// 挂载方持有 renderer；此控件管理媒体订阅、帧调度与绘制挂载。
class DanmakuWindowScreen<T> extends StatefulWidget {
  const DanmakuWindowScreen({
    super.key,
    required this.renderer,
    required this.clock,
    required this.size,
    required this.prepareFrame,
    this.needsPreparation,
    this.nextPreparationUs,
    this.inputChanges,
    this.opacity = 1,
    this.frameRate = 0,
    this.frameSource = const EmptyPlaybackFrameSource(),
    this.monotonicUs,
    this.frameTimeUs,
  });

  final DanmakuWindowRenderer<T> renderer;
  final PlaybackMediaClock clock;
  final Size size;
  final DanmakuPrepareFrame<T> prepareFrame;
  final bool Function()? needsPreparation;
  final int? Function()? nextPreparationUs;
  final Stream<Object?>? inputChanges;
  final double opacity;
  final int frameRate;
  final PlaybackFrameSource frameSource;
  final int Function()? monotonicUs;

  /// 与单调时钟同域的帧目标时间；测试可分别控制目标与实际交付。
  final int Function()? frameTimeUs;

  @override
  State<DanmakuWindowScreen<T>> createState() => _DanmakuWindowScreenState<T>();
}

class _DanmakuWindowScreenState<T> extends State<DanmakuWindowScreen<T>> {
  late final DanmakuFrameScheduler _scheduler;
  StreamSubscription<PlaybackMediaAnchor?>? _anchors;
  StreamSubscription<Object?>? _inputs;
  PlaybackMediaAnchor? _anchor;
  int? _continuity;
  int _lastPositionUs = 0;
  int? _lastFrameTimeUs;
  bool _settlingClock = false;
  int? _pausedAtUs;
  bool _enabled = false;
  FlutterView? _view;
  Timer? _wake;
  late final VoidCallback _unregisterDiagnostics;

  @override
  void initState() {
    super.initState();
    _scheduler = DanmakuFrameScheduler(
      onFrame: (frame) => _update(frame: frame),
    );
    _unregisterDiagnostics = Diagnostics.instance.register(
      'danmaku.layer.$hashCode',
      () => {
        ...widget.renderer.statistics,
        'input': 'timeline',
        'visible': _visible,
        'opacity': widget.opacity,
        'tickerEnabled': _enabled,
        'presentationTimeUs': widget.renderer.presentationTimeUs,
        'sampledAtUs': widget.monotonicUs?.call() ?? Timeline.now,
        'mediaAnchor': {
          'positionUs': _anchor?.positionUs,
          'observedAtUs': _anchor?.observedAtUs,
          'effectiveRate': _anchor?.effectiveRate,
          'advancing': _anchor?.advancing,
          'ready': _anchor?.ready,
          'continuity': _anchor?.continuity,
          'validForUs': _anchor?.validForUs,
        },
        'scheduler': _scheduler.diagnostics,
      },
    );
    widget.renderer.addListener(_syncScheduler);
    _bindClock();
    _bindInputs();
  }

  void _bindClock() {
    _anchors = widget.clock.mediaAnchors.listen(
      _acceptAnchor,
      onDone: () => _acceptAnchor(null),
    );
    _acceptAnchor(widget.clock.currentMediaAnchor);
  }

  void _bindInputs() {
    _inputs = widget.inputChanges?.listen((_) {
      _scheduler.requestFrame();
    });
  }

  void _acceptAnchor(PlaybackMediaAnchor? anchor) {
    final previous = _anchor;
    _anchor = anchor;
    if (anchor != null &&
        previous != null &&
        anchor.continuity == previous.continuity &&
        anchor.effectiveRate != previous.effectiveRate) {
      _settlingClock = true;
    }
    if (anchor == null || !anchor.ready) {
      _continuity = null;
      _pausedAtUs = null;
      widget.renderer.suspendPresentation();
    }
    final boundary = previous?.continuity == anchor?.continuity;
    final now = widget.monotonicUs?.call() ?? Timeline.now;
    if (boundary && previous?.advancing == true && anchor?.advancing == false) {
      _pausedAtUs ??= now;
      _settlingClock = true;
    } else if (boundary && anchor?.advancing == true && _pausedAtUs != null) {
      if (_lastFrameTimeUs case final previousFrame?) {
        _lastFrameTimeUs = previousFrame + math.max(0, now - _pausedAtUs!);
      }
      _pausedAtUs = null;
    }
    _syncScheduler();
    if ((!_scheduler.isContinuous && anchor?.advancing == true) ||
        previous == null ||
        previous.ready != anchor?.ready ||
        previous.effectiveRate != anchor?.effectiveRate ||
        previous.advancing != anchor?.advancing ||
        !boundary) {
      _scheduler.requestFrame();
    }
  }

  bool get _visible => _enabled && widget.opacity > 0 && !widget.size.isEmpty;

  void _update({required DanmakuFrame frame}) {
    final frameTimeUs = widget.frameTimeUs?.call() ?? frame.targetUs;
    if (!_visible) {
      _pausedAtUs = null;
      _lastFrameTimeUs = null;
      return;
    }
    final anchor = _anchor;
    final updateTimeUs = frameTimeUs;
    var position = anchor?.positionAt(updateTimeUs);
    int? nextFrameTimeUs = frameTimeUs;
    if (position == null) return;
    final renderer = widget.renderer;
    if (_continuity != anchor!.continuity) {
      if (!renderer.containsPreparedTime(position)) renderer.reset(position);
      _continuity = anchor.continuity;
      _settlingClock = false;
      _pausedAtUs = null;
    } else {
      final previousFrame = _lastFrameTimeUs;
      if (_pausedAtUs != null) {
        // 状态交接保留已呈现相位，帧目标原点仅平移实际暂停时长。
        position = _lastPositionUs;
        _settlingClock = true;
        if (!anchor.advancing) {
          _pausedAtUs ??= updateTimeUs;
          nextFrameTimeUs = previousFrame ?? updateTimeUs;
        } else {
          final pausedUs = math.max(0, updateTimeUs - _pausedAtUs!);
          nextFrameTimeUs = (previousFrame ?? updateTimeUs) + pausedUs;
          _pausedAtUs = null;
        }
      } else if (previousFrame != null && frameTimeUs <= previousFrame) {
        position = _lastPositionUs;
        nextFrameTimeUs = previousFrame;
      } else if (previousFrame != null &&
          frameTimeUs > previousFrame &&
          (frameTimeUs - previousFrame <= 50000 || _settlingClock) &&
          anchor.advancing &&
          frameTimeUs < anchor.observedAtUs + anchor.validForUs) {
        final advance = (frameTimeUs - previousFrame) * anchor.effectiveRate;
        final projected = _lastPositionUs + advance.round();
        final error = position - projected;
        // time-pos 随视频帧离散推进，接收时刻还包含通知延迟。
        // 连续帧的小幅校准分摊到后续帧，速度偏差限于 5%。
        // 降速后的采样差仍包含旧速率下的离散位置误差，继续平滑收敛。
        // 普通播放超过 50ms 的空档重新贴合；切速交接继续消化已有相位差。
        final nearAnchor = error.abs() <= 100000 * anchor.effectiveRate;
        if ((nearAnchor || _settlingClock) &&
            frameTimeUs - previousFrame < anchor.validForUs) {
          final correction = (advance * .05).round();
          position = projected + error.clamp(-correction, correction);
          if (error.abs() <= correction) _settlingClock = false;
        }
      }
      // 原生校准可能落后于已外推的画面，同一连续域等待媒体时间追上。
      position = math.max(
        position,
        math.max(_lastPositionUs, renderer.validFromUs),
      );
    }
    _lastPositionUs = position;
    _lastFrameTimeUs = nextFrameTimeUs;
    renderer
      ..prepareConfiguration()
      ..present(position, allowUnprepared: true);
    widget.prepareFrame(
      renderer,
      position,
      effectiveRate: anchor.effectiveRate,
    );
    renderer.present(position, allowUnprepared: true);
    _syncScheduler();
  }

  void _syncScheduler() {
    _wake?.cancel();
    _wake = null;
    final now = widget.monotonicUs?.call() ?? Timeline.now;
    final anchor = _anchor;
    final advancing =
        anchor != null &&
        anchor.advancing &&
        now - anchor.observedAtUs < anchor.validForUs;
    final animate =
        _visible &&
        (_anchor?.ready ?? false) &&
        (widget.renderer.hasPendingConfiguration ||
            (widget.needsPreparation?.call() ?? false) ||
            (advancing && widget.renderer.needsContinuousFrames));
    if (_view case final view?) {
      _scheduler.configure(
        view: view,
        source: widget.frameSource,
        targetFrameRate: widget.frameRate,
        enabled: _visible,
        continuous: animate,
      );
    }
    if (!_visible || animate || !advancing || !anchor.ready) return;
    final position = anchor.positionAt(now)!;
    final deadlines = [
      ?widget.renderer.nextChangeUs,
      ?widget.nextPreparationUs?.call(),
    ];
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a < b ? a : b);
    final delay = ((next - position) / anchor.effectiveRate).ceil();
    final freshness = anchor.observedAtUs + anchor.validForUs - now;
    _wake = Timer(
      Duration(microseconds: delay.clamp(0, freshness)),
      _scheduler.requestFrame,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    final wasEnabled = _enabled;
    _enabled = TickerMode.valuesOf(context).enabled;
    if (wasEnabled && !_enabled) {
      _lastFrameTimeUs = null;
      _pausedAtUs = null;
      widget.renderer.suspendPresentation();
    }
    _syncScheduler();
    _scheduler.requestFrame();
  }

  @override
  void didUpdateWidget(covariant DanmakuWindowScreen<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) {
      unawaited(_anchors?.cancel());
      _continuity = null;
      widget.renderer.reset(_lastPositionUs);
      _bindClock();
    }
    if (!identical(oldWidget.inputChanges, widget.inputChanges)) {
      unawaited(_inputs?.cancel());
      _bindInputs();
    }
    if (!identical(oldWidget.renderer, widget.renderer)) {
      oldWidget.renderer.removeListener(_syncScheduler);
      widget.renderer.addListener(_syncScheduler);
      _continuity = null;
    }
    if (!_scheduler.isContinuous ||
        !identical(oldWidget.renderer, widget.renderer)) {
      _scheduler.requestFrame();
    }
    _syncScheduler();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !_visible,
    child: IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: widget.size,
          painter: _WindowPainter(widget.renderer, widget.opacity),
          willChange: _scheduler.isContinuous,
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _unregisterDiagnostics();
    _wake?.cancel();
    widget.renderer.removeListener(_syncScheduler);
    unawaited(_anchors?.cancel());
    unawaited(_inputs?.cancel());
    _scheduler.dispose();
    super.dispose();
  }
}

class _WindowPainter<T> extends CustomPainter {
  _WindowPainter(this.renderer, this.opacity) : super(repaint: renderer);
  final DanmakuWindowRenderer<T> renderer;
  final double opacity;
  @override
  void paint(Canvas canvas, Size size) =>
      renderer.paint(canvas, size, opacity: opacity);
  @override
  bool shouldRepaint(covariant _WindowPainter<T> oldDelegate) =>
      !identical(renderer, oldDelegate.renderer) ||
      opacity != oldDelegate.opacity;
}
