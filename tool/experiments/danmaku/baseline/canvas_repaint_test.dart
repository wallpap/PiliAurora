import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 360);

Future<DanmakuController<void>> _mount(
  WidgetTester tester, {
  int frameRate = 0,
}) async {
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
              frameRate: frameRate,
              option: const DanmakuOption(
                fontSize: 20,
                duration: 8,
                massiveMode: true,
              ),
              size: _size,
              createdController: (value) => controller = value,
            ),
          ),
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('普通绘制器重复绘制不改变位置、时间与过期状态', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(DanmakuContentItem<void>('readonly'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final item = controller.scrollDanmaku.first.single;
    final before = (item.xPosition, item.drawTick, item.expired);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<ScrollDanmakuPainter>()
        .single;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    painter
      ..paint(canvas, _size)
      ..paint(canvas, _size);
    recorder.endRecording().dispose();
    expect((item.xPosition, item.drawTick, item.expired), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('图层不绘制时普通弹幕仍按更新时钟运动并到期', (tester) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: _size),
          child: Opacity(
            opacity: 0,
            child: SizedBox.fromSize(
              size: _size,
              child: DanmakuScreen<void>(
                size: _size,
                option: const DanmakuOption(fontSize: 20, duration: 1),
                createdController: (value) => controller = value,
              ),
            ),
          ),
        ),
      ),
    );
    controller.addDanmaku(DanmakuContentItem<void>('hidden'));
    await tester.pump();
    final item = controller.scrollDanmaku.first.single;
    final start = item.xPosition;
    await tester.pump(const Duration(milliseconds: 100));
    expect(item.xPosition, lessThan(start));
    for (var frame = 0; frame < 15; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.scrollDanmaku.every((track) => track.isEmpty), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('120 FPS 档位在 120 Hz 上实际绘制对应数量的运动帧', (tester) async {
    const fps = 120;
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final controller = await _mount(tester, frameRate: fps);
    controller.addDanmaku(DanmakuContentItem<void>('高刷滚动'));
    await tester.pump();
    final item = controller.scrollDanmaku.first.single;
    final initialUpdates = controller.schedulerDiagnostics['updates'] as int;
    var paints = 0;
    for (var slot = 1; slot <= 480; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      // 同时提供 60 FPS 的外部帧，检查绘制没有退回视频帧率。
      if (slot.isEven) tester.binding.scheduleFrame();
      final previous = item.drawTick;
      if (tester.binding.hasScheduledFrame) await tester.pump();
      if (item.drawTick != previous) paints++;
    }
    final updates =
        (controller.schedulerDiagnostics['updates'] as int) - initialUpdates;
    expect(controller.schedulerDiagnostics['targetFrameRate'], fps);
    expect(updates, closeTo(fps * 4, 1));
    expect(paints, closeTo(fps * 4, 1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定弹幕同帧等数量替换后绘制新项并正常到期', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final controller = await _mount(tester, frameRate: 60);
    controller.updateOption(controller.option.copyWith(staticDuration: .05));
    controller.addDanmaku(
      DanmakuContentItem<void>('old', type: DanmakuItemType.top),
    );
    await tester.pump();
    final old = controller.staticDanmaku.nonNulls.single;
    expect(old.drawTick, isNotNull);
    expect(controller.schedulerDiagnostics['updates'], greaterThan(0));
    expect(controller.schedulerDiagnostics['targetFrameRate'], 60);
    for (var slot = 1; slot <= 20; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    expect(controller.staticDanmaku.nonNulls.single, same(old));
    await tester.binding.delayed(const Duration(microseconds: 8334));
    expect(tester.binding.hasScheduledFrame, isFalse);
    controller.addDanmaku(
      DanmakuContentItem<void>('new', type: DanmakuItemType.bottom),
    );
    final fresh = controller.staticDanmaku.nonNulls.last;
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.binding.delayed(const Duration(microseconds: 8334));
    await tester.pump();
    expect(controller.staticDanmaku.nonNulls.single, same(fresh));
    expect(fresh.drawTick, isNotNull);
    expect(old.image, isNull);
    for (var slot = 0; slot < 60; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    expect(controller.staticDanmaku.nonNulls, isEmpty);
    expect(fresh.image, isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('120 条滚动、固定和高级弹幕共用 60 FPS 绘制帧', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final controller = await _mount(tester, frameRate: 60);
    controller.updateOption(controller.option.copyWith(staticDuration: .05));
    for (var i = 0; i < 120; i++) {
      expect(controller.addDanmaku(DanmakuContentItem<void>('滚动 $i')), isTrue);
    }
    controller.addDanmaku(
      SpecialDanmakuContentItem<void>(
        '高级',
        duration: 8000,
        color: const Color(0xFFFFFFFF),
        fontSize: 20,
        translateXTween: Tween(begin: .1, end: .5),
        translateYTween: ConstantTween(.1),
      ),
    );
    await tester.pump();
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
    final scroll = painters
        .map((widget) => widget.painter)
        .whereType<ScrollDanmakuPainter>()
        .single;
    final special = painters
        .map((widget) => widget.painter)
        .whereType<SpecialDanmakuPainter>()
        .single;
    final scrollSlots = <int>[];
    final specialSlots = <int>[];
    var slot = 0;
    void onScroll() => scrollSlots.add(slot);
    void onSpecial() => specialSlots.add(slot);
    scroll.addListener(onScroll);
    special.addListener(onSpecial);
    for (slot = 1; slot <= 360; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      if (slot % 12 == 1) {
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(
          controller.addDanmaku(
            DanmakuContentItem<void>(
              '固定 $slot',
              type: (slot ~/ 12).isEven
                  ? DanmakuItemType.top
                  : DanmakuItemType.bottom,
            ),
          ),
          isTrue,
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    scroll.removeListener(onScroll);
    special.removeListener(onSpecial);
    expect(scrollSlots.length, 180);
    expect(specialSlots, scrollSlots);
    expect(scroll.tick, special.tick);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final type in [DanmakuItemType.top, DanmakuItemType.bottom]) {
    testWidgets('固定弹幕 $type 新增与运动弹幕共用限频绘制帧', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final controller = await _mount(tester, frameRate: 60);
      controller.addDanmaku(DanmakuContentItem<void>('moving'));
      await tester.pump();
      await tester.binding.delayed(const Duration(microseconds: 8334));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        controller.addDanmaku(DanmakuContentItem<void>('fixed', type: type)),
        isTrue,
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.binding.delayed(const Duration(microseconds: 8334));
      await tester.pump();
      final fixed = controller.staticDanmaku.nonNulls.single;
      final moving = controller.scrollDanmaku.first.single;
      expect(fixed.drawTick, isNotNull);
      expect(fixed.drawTick, moving.drawTick);
      controller.pause();
      controller.clear();
      await tester.pump();
      expect(controller.staticDanmaku.nonNulls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('固定弹幕 $type 单独出现时首帧可见，暂停恢复后继续清理', (tester) async {
      final controller = await _mount(tester, frameRate: 60);
      controller.addDanmaku(DanmakuContentItem<void>('fixed', type: type));
      await tester.pump();
      final fixed = controller.staticDanmaku.nonNulls.single;
      expect(fixed.drawTick, isNotNull);
      controller.pause();
      await tester.pump(const Duration(seconds: 6));
      expect(controller.staticDanmaku.nonNulls.single, same(fixed));
      controller.resume();
      await tester.pump();
      for (var i = 0; i < 360; i++) {
        await tester.pump(const Duration(milliseconds: 17));
      }
      expect(controller.staticDanmaku.nonNulls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('缓存后的普通弹幕连续绘制不重建 widget', (tester) async {
    final controller = await _mount(tester);
    for (var i = 0; i < 120; i++) {
      expect(controller.addDanmaku(DanmakuContentItem<void>('弹幕 $i')), isTrue);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final item = controller.scrollDanmaku.first.first;
    final startX = item.xPosition;
    final image = item.image;
    var rebuilds = 0;
    var emptyLayerRepaints = 0;
    final emptyPainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<SpecialDanmakuPainter>()
        .single;
    void onEmptyRepaint() => emptyLayerRepaints++;
    emptyPainter.addListener(onEmptyRepaint);
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (_, _) => rebuilds++;
    try {
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect(item.xPosition, lessThan(startX));
    expect(item.image, same(image));
    expect(rebuilds, 0);
    expect(emptyLayerRepaints, 0);
    emptyPainter.removeListener(onEmptyRepaint);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点击仅悬停选中的弹幕，其他弹幕继续移动并复用图片', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(DanmakuContentItem<void>('selected'));
    controller.addDanmaku(DanmakuContentItem<void>('moving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final selected = controller.scrollDanmaku[0].single;
    final moving = controller.scrollDanmaku[1].single;
    final hit = controller.findSingleDanmaku(Offset(selected.xPosition + 1, 1));
    expect(hit?.$2, same(selected));
    selected.suspend = true;
    final selectedX = selected.xPosition;
    final movingX = moving.xPosition;
    final selectedImage = selected.image;
    final movingImage = moving.image;
    await tester.pump(const Duration(milliseconds: 200));
    expect(selected.xPosition, selectedX);
    expect(moving.xPosition, lessThan(movingX));
    expect(selected.image, same(selectedImage));
    expect(moving.image, same(movingImage));
    expect(
      controller.findSingleDanmaku(Offset(selected.xPosition + 1, 1))?.$2,
      same(selected),
    );
    selected.suspend = false;
    await tester.pump(const Duration(milliseconds: 100));
    final expectedDistance = (_size.width + selected.width) / 8000 * 100;
    expect(selectedX - selected.xPosition, closeTo(expectedDistance, .01));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('更改速度、暂停恢复和清空后，重绘使用当前状态', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(DanmakuContentItem<void>('speed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final item = controller.scrollDanmaku.first.single;
    final initialX = item.xPosition;
    controller.updateOption(controller.option.copyWith(duration: 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      initialX - item.xPosition,
      closeTo((_size.width + item.width) / 4000 * 100, .01),
    );
    controller.pause();
    final pausedX = item.xPosition;
    await tester.pump(const Duration(seconds: 1));
    expect(item.xPosition, pausedX);
    controller.resume();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(item.xPosition, lessThan(pausedX));
    controller.pause();
    controller.clear();
    await tester.pump();
    expect(controller.scrollDanmaku.every((track) => track.isEmpty), isTrue);
    expect(controller.findSingleDanmaku(Offset(pausedX + 1, 1)), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('高级弹幕复用绘制委托时仍推进时间并按期清理', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(
      SpecialDanmakuContentItem<void>(
        'special',
        duration: 500,
        color: const Color(0xFFFFFFFF),
        fontSize: 20,
        translateXTween: Tween(begin: .1, end: .5),
        translateYTween: ConstantTween(.1),
        alphaTween: Tween(begin: .3, end: 1),
      ),
    );
    final item = controller.specialDanmaku.single;
    final image = item.image;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(item.drawTick, isNotNull);
    expect(item.expired, isFalse);
    expect(item.image, same(image));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.specialDanmaku, isEmpty);
    expect(item.image, isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧 Canvas 弹幕屏幕在 TickerMode 静音后停止请求帧', (tester) async {
    late DanmakuController<void> controller;
    Widget screen(bool enabled) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: TickerMode(
          enabled: enabled,
          child: DanmakuScreen<void>(
            option: const DanmakuOption(),
            size: const Size(800, 600),
            frameRate: 60,
            createdController: (value) => controller = value,
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen(true));
    controller.addDanmaku(DanmakuContentItem<void>('moving'));
    await tester.pump();
    await tester.pumpWidget(screen(false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('并存图层使用各自 DPI，密度变化重新栅格且保留表情资源', (tester) async {
    final controllers = <int, DanmakuController<void>>{};
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFFF0000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final emote = picture.toImageSync(8, 8);
    picture.dispose();
    Widget layer(int id, double ratio) => MediaQuery(
      data: MediaQueryData(devicePixelRatio: ratio),
      child: SizedBox(
        width: 300,
        height: 120,
        child: DanmakuScreen<void>(
          key: ValueKey(id),
          size: const Size(300, 120),
          option: const DanmakuOption(fontSize: 20),
          createdController: (controller) => controllers[id] = controller,
        ),
      ),
    );
    Future<void> mount(double ratio) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(children: [layer(1, 1), layer(2, ratio)]),
      ),
    );
    await mount(2);
    controllers[1]!.addDanmaku(DanmakuContentItem<void>('same'));
    controllers[2]!.addDanmaku(DanmakuContentItem<void>('same'));
    await tester.pump();
    final a = controllers[1]!.scrollDanmaku.first.single;
    final b = controllers[2]!.scrollDanmaku.first.single;
    expect(a.width, b.width);
    expect(a.image!.width, a.width.ceil());
    expect(b.image!.width, (b.width * 2).ceil());
    controllers[2]!.addDanmaku(
      DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: emote,
            width: 8,
            height: 8,
          ),
        ],
      ),
    );
    await tester.pump();
    controllers[2]!.pause();
    await mount(1);
    await tester.pump();
    expect(b.image!.width, b.width.ceil());
    expect(emote.debugDisposed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(emote.debugDisposed, isTrue);
  });
}
