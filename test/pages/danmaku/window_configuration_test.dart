import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const option = DanmakuOption(fontSize: 20, safeArea: false);
  DanmakuWindowRenderer<void> create() {
    final renderer = DanmakuWindowRenderer<void>(
      option: option,
      size: const Size(640, 360),
    );
    renderer.prepare(
      [
        for (var i = 0; i < 3; i++)
          DanmakuWindowContent('$i', 0, DanmakuContentItem<void>('item$i')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 10000000,
    );
    renderer.present(1000000);
    addTearDown(renderer.dispose);
    return renderer;
  }

  test('configuration preparation is bounded, coalesced and committed with hit geometry', () {
    final renderer = create();
    final handle = renderer.interaction..select('0');
    final before = handle.snapshot.firstWhere((item) => item.identity == '0');
    final generation = renderer.generation;
    renderer.requestConfiguration(
      option: option.copyWith(fontSize: 30),
      size: const Size(640, 360),
      devicePixelRatio: 2,
    );
    expect(renderer.prepareConfiguration(maxItems: 1), isFalse);
    renderer.present(1000000, allowUnprepared: true);
    expect(renderer.generation, generation);
    expect(
      handle.snapshot.firstWhere((item) => item.identity == '0').bounds,
      before.bounds,
    );
    renderer.requestConfiguration(
      option: option.copyWith(fontSize: 40),
      size: const Size(800, 360),
      devicePixelRatio: 1.5,
      fontFamily: 'sans-serif',
    );
    // 新配置包含三项；每次只准备一项，必须在第三次结束。
    expect(renderer.prepareConfiguration(maxItems: 1), isFalse);
    expect(renderer.prepareConfiguration(maxItems: 1), isFalse);
    expect(renderer.prepareConfiguration(maxItems: 1), isTrue);
    expect(renderer.rasters.option.fontSize, 20);
    renderer.present(1500000, allowUnprepared: true);
    expect(renderer.rasters.option.fontSize, 40);
    expect(renderer.rasters.devicePixelRatio, 1.5);
    expect(renderer.validFromUs, 1500000);
    expect(renderer.generation, greaterThan(generation));
    final after = handle.snapshot.firstWhere((item) => item.identity == '0');
    expect(after.selected, isTrue);
    expect(after.bounds.topLeft, before.bounds.topLeft);
    expect(after.bounds.width, greaterThan(before.bounds.width));
    expect(handle.hitTest(after.bounds.center)?.identity, '0');
    expect(handle.clearSelection(), isTrue);
  });

  test('area shrink clips hits immediately and reset releases prepared resources and keeps latest settings', () {
    final renderer = create()
      ..requestConfiguration(
        option: option.copyWith(area: 0.1),
        size: const Size(640, 360),
        devicePixelRatio: 1,
      );
    expect(renderer.hitTest(const Offset(600, 100)), isNull);
    renderer
      ..prepareConfiguration(maxItems: 1)
      ..reset(5000000);
    expect(renderer.hasPendingConfiguration, isTrue);
    renderer.present(5000000, allowUnprepared: true);
    expect(renderer.rasters.option.area, 0.1);
    expect(renderer.activeBytes, 0);
  });
  test('identical targets preserve preparation and shared backing stays within peak budget', () {
    final renderer = create();
    final optionNext = option.copyWith(fontSize: 28);
    renderer.requestConfiguration(
      option: optionNext,
      size: const Size(640, 360),
      devicePixelRatio: 1,
    );
    expect(renderer.prepareConfiguration(maxItems: 1), isFalse);
    renderer.requestConfiguration(
      option: optionNext.copyWith(),
      size: const Size(640, 360),
      devicePixelRatio: 1,
    );
    expect(renderer.prepareConfiguration(maxItems: 1), isFalse);
    expect(renderer.prepareConfiguration(maxItems: 1), isTrue);
    expect(
      renderer.workingSetBytes,
      lessThanOrEqualTo(renderer.maxWorkingSetBytes),
    );
    renderer.present(1000000, allowUnprepared: true);
    final generation = renderer.generation;
    renderer.requestConfiguration(
      option: optionNext.copyWith(),
      size: const Size(640, 360),
      devicePixelRatio: 1,
    );
    expect(renderer.hasPendingConfiguration, isFalse);
    expect(renderer.generation, generation);
  });
}
