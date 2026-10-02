import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

class WindowsDanmakuScreen<T> extends StatefulWidget {
  const WindowsDanmakuScreen({
    super.key,
    required this.option,
    required this.size,
    required this.createdRenderer,
    this.opacity = 1,
  });

  final DanmakuOption option;
  final Size size;
  final double opacity;
  final ValueChanged<WindowsDanmakuRenderer<T>> createdRenderer;

  @override
  State<WindowsDanmakuScreen<T>> createState() =>
      _WindowsDanmakuScreenState<T>();
}

class _WindowsDanmakuScreenState<T> extends State<WindowsDanmakuScreen<T>>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _opacity;
  WindowsDanmakuRenderer<T>? _renderer;
  late _WindowsDanmakuPainter<T> _painter;
  VoidCallback? _unregisterDiagnostics;
  Duration _lastElapsed = Duration.zero;
  bool _ancestorEnabled = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final delta = elapsed - _lastElapsed;
      _lastElapsed = elapsed;
      _renderer!.advance(delta);
    });
    _opacity = AnimationController(
      vsync: this,
      value: widget.opacity,
      duration: const Duration(milliseconds: 100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ancestorEnabled = TickerMode.valuesOf(context).enabled;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final family = DefaultTextStyle.of(context).style.fontFamily;
    if (_renderer == null) {
      final renderer = _renderer = WindowsDanmakuRenderer<T>(
        option: widget.option,
        size: widget.size,
        devicePixelRatio: ratio,
        fontFamily: family,
      );
      _painter = _WindowsDanmakuPainter<T>(renderer, _opacity);
      renderer.addListener(_syncTicker);
      _unregisterDiagnostics = Diagnostics.instance.register(
        'danmaku.renderer.$hashCode',
        () => renderer.statistics,
      );
      widget.createdRenderer(renderer);
    } else {
      _renderer!.configure(
        devicePixelRatio: ratio,
        fontFamily: family,
        useDefaultFontFamily: family == null,
      );
    }
    _syncTicker();
  }

  @override
  void didUpdateWidget(WindowsDanmakuScreen<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _renderer!.configure(option: widget.option, size: widget.size);
    if (widget.opacity != oldWidget.opacity) {
      if (widget.opacity == 0) {
        _opacity.value = 0;
      } else {
        _opacity.animateTo(widget.opacity);
      }
    }
    _syncTicker();
  }

  void _syncTicker() {
    final renderer = _renderer;
    if (renderer == null) return;
    renderer.prewarmingAllowed = _ancestorEnabled && widget.opacity > 0;
    final animate =
        renderer.prewarmingAllowed && renderer.running && !renderer.isEmpty;
    if (animate && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!animate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: widget.opacity == 0,
    child: IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _painter,
          size: widget.size,
          willChange: true,
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _unregisterDiagnostics?.call();
    _renderer?.removeListener(_syncTicker);
    _ticker.dispose();
    _opacity.dispose();
    _renderer?.dispose();
    super.dispose();
  }
}

class _WindowsDanmakuPainter<T> extends CustomPainter {
  _WindowsDanmakuPainter(this.renderer, this.opacity)
    : super(repaint: Listenable.merge([renderer, opacity]));

  final WindowsDanmakuRenderer<T> renderer;
  final Animation<double> opacity;

  @override
  void paint(Canvas canvas, Size size) =>
      renderer.paint(canvas, size, opacity: opacity.value);

  @override
  bool shouldRepaint(covariant _WindowsDanmakuPainter<T> oldDelegate) => false;
}
