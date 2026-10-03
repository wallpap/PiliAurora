import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';
import 'package:pili_aurora/pages/danmaku/windows_screen.dart';

const _size = Size(960, 540);
const _option = DanmakuOption(
  fontSize: 20,
  duration: 8,
  massiveMode: true,
);

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: _size),
    child: Center(
      child: SizedBox.fromSize(size: _size, child: child),
    ),
  ),
);

void main() {
  testWidgets('screen passes creation-time cache limits to renderer', (
    tester,
  ) async {
    late WindowsDanmakuRenderer<void> renderer;
    await tester.pumpWidget(
      _host(
        WindowsDanmakuScreen<void>(
          option: _option,
          size: _size,
          rasterCacheMaxBytes: 24 * 1024 * 1024,
          rasterCacheMaxEntries: 128,
          createdRenderer: (value) => renderer = value,
        ),
      ),
    );
    expect(renderer.statistics['cacheImageLimitBytes'], 24 * 1024 * 1024);
    expect(renderer.statistics['cacheEntryLimit'], 128);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hidden and ancestor-muted screens freeze then resume without a time jump',
    (tester) async {
      late WindowsDanmakuRenderer<void> renderer;
      Widget screen({double opacity = 1, bool enabled = true}) => _host(
        TickerMode(
          enabled: enabled,
          child: WindowsDanmakuScreen<void>(
            option: _option,
            size: _size,
            opacity: opacity,
            createdRenderer: (value) => renderer = value,
          ),
        ),
      );
      await tester.pumpWidget(screen());
      renderer.add(
        DanmakuContentItem<void>('moving', color: const Color(0xFFFFFFFF)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final tick = renderer.tick;
      await tester.pumpWidget(screen(opacity: 0));
      await tester.pump(const Duration(seconds: 20));
      expect(renderer.tick, tick);
      expect(renderer.prewarmingAllowed, isFalse);
      await tester.pumpWidget(screen(enabled: false));
      await tester.pump(const Duration(seconds: 20));
      expect(renderer.tick, tick);
      await tester.pumpWidget(screen());
      await tester.pump(const Duration(milliseconds: 100));
      expect(renderer.tick, tick + 100);
      expect(renderer.isEmpty, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('prewarm makes progress during an active animation', (
    tester,
  ) async {
    late WindowsDanmakuRenderer<void> renderer;
    await tester.pumpWidget(
      _host(
        WindowsDanmakuScreen<void>(
          option: _option,
          size: _size,
          createdRenderer: (value) => renderer = value,
        ),
      ),
    );
    renderer
      ..add(
        DanmakuContentItem<void>('active', color: const Color(0xFFFFFFFF)),
      )
      ..queuePrewarm(
        List.generate(
          12,
          (index) => DanmakuContentItem<void>(
            'future $index',
            color: const Color(0xFFFFFFFF),
          ),
        ),
      );
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(renderer.rasters.rasterizations, 13);
    expect(renderer.statistics['pendingPrewarm'], 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('baseline records animation rebuilds', (tester) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      _host(
        DanmakuScreen<void>(
          option: _option,
          size: _size,
          createdController: (value) => controller = value,
        ),
      ),
    );
    for (var index = 0; index < 120; index++) {
      controller.addDanmaku(
        DanmakuContentItem(
          '已缓冲弹幕 ${index % 12}',
          color: const Color(0xFFFFFFFF),
        ),
      );
    }
    await tester.pump();
    var rebuilds = 0;
    final previousCallback = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ValueListenableBuilder) rebuilds++;
    };
    final stopwatch = Stopwatch()..start();
    try {
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    } finally {
      stopwatch.stop();
      debugOnRebuildDirtyWidget = previousCallback;
    }
    debugPrint(
      'DANMAKU_BASELINE frames=120 rebuilds=$rebuilds '
      'pumpMicroseconds=${stopwatch.elapsedMicroseconds}',
    );
    expect(rebuilds, greaterThanOrEqualTo(120));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'prepared renderer does not rebuild widgets per animation frame',
    (tester) async {
      late WindowsDanmakuRenderer<void> renderer;
      await tester.pumpWidget(
        _host(
          WindowsDanmakuScreen<void>(
            option: _option,
            size: _size,
            createdRenderer: (value) => renderer = value,
          ),
        ),
      );
      for (var index = 0; index < 120; index++) {
        renderer.add(
          DanmakuContentItem<void>(
            '已缓冲弹幕 ${index % 12}',
            color: const Color(0xFFFFFFFF),
          ),
        );
      }
      await tester.pump();
      var rebuilds = 0;
      final previousCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) => rebuilds++;
      final stopwatch = Stopwatch()..start();
      try {
        for (var frame = 0; frame < 120; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      } finally {
        stopwatch.stop();
        debugOnRebuildDirtyWidget = previousCallback;
      }
      debugPrint(
        'DANMAKU_PREPARED frames=120 rebuilds=$rebuilds '
        'rasterizations=${renderer.rasters.rasterizations} '
        'pumpMicroseconds=${stopwatch.elapsedMicroseconds}',
      );
      expect(rebuilds, 0);
      expect(renderer.rasters.rasterizations, 12);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
