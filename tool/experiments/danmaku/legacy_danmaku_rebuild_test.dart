import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(960, 540);
const _option = DanmakuOption(fontSize: 20, duration: 8, massiveMode: true);

void main() {
  testWidgets('legacy renderer animation rebuild measurement', (tester) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: _size),
          child: Center(
            child: SizedBox.fromSize(
              size: _size,
              child: DanmakuScreen<void>(
                option: _option,
                size: _size,
                createdController: (value) => controller = value,
              ),
            ),
          ),
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
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
