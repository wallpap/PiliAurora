import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TabBarView, TabController;
import 'package:pili_aurora/common/widgets/inactive_paint_cleanup.dart';
import 'package:pili_aurora/common/widgets/inactive_feed_sliver.dart';
import 'package:pili_aurora/common/widgets/tab_activity.dart';

import 'retained_layer_cleanup_prototype.dart';

// 仅用于验证：正常的离屏保活不会释放旧 Picture；清理层内容是否能保留状态。
class _RetainedPage extends StatefulWidget {
  const _RetainedPage({
    super.key,
    required this.bytes,
    required this.cellKey,
    this.externalContent = false,
    this.showImagesOverride,
  });

  final Uint8List bytes;
  final GlobalKey cellKey;
  final bool externalContent;
  final bool? showImagesOverride;

  @override
  State<_RetainedPage> createState() => _RetainedPageState();
}

class _RetainedPageState extends State<_RetainedPage>
    with AutomaticKeepAliveClientMixin {
  final controller = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final active =
        widget.showImagesOverride ?? TickerMode.valuesOf(context).enabled;
    final list = ListView.builder(
      controller: controller,
      itemCount: 12,
      itemBuilder: (_, index) => RepaintBoundary(
        key: index == 1 ? widget.cellKey : null,
        child: SizedBox(
          height: 100,
          child: active
              ? Image.memory(widget.bytes, fit: BoxFit.fill)
              : const SizedBox.expand(),
        ),
      ),
    );
    return widget.externalContent
        ? Stack(children: [list, const Texture(textureId: 1)])
        : list;
  }
}

List<ui.Picture> _pictures(ContainerLayer layer) {
  final result = <ui.Picture>[];
  void visit(Layer layer) {
    if (layer is PictureLayer) result.add(layer.picture!);
    if (layer is ContainerLayer) {
      var child = layer.firstChild;
      while (child != null) {
        visit(child);
        child = child.nextSibling;
      }
    }
  }

  visit(layer);
  return result;
}

Future<Uint8List> _redPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _TrackedOffsetLayer extends OffsetLayer {
  ui.EngineLayer? get currentEngineLayer => engineLayer;
  int engineUpdates = 0;

  @override
  set engineLayer(ui.EngineLayer? value) {
    engineUpdates++;
    super.engineLayer = value;
  }
}

class _TrackedBoundary extends SingleChildRenderObjectWidget {
  const _TrackedBoundary({super.key, required super.child});

  @override
  _RenderTrackedBoundary createRenderObject(BuildContext context) =>
      _RenderTrackedBoundary();
}

class _RenderTrackedBoundary extends RenderRepaintBoundary {
  @override
  _TrackedOffsetLayer updateCompositedLayer({OffsetLayer? oldLayer}) =>
      oldLayer as _TrackedOffsetLayer? ?? _TrackedOffsetLayer();
}

class _VirtualizedPaintPage extends StatefulWidget {
  const _VirtualizedPaintPage({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<_VirtualizedPaintPage> createState() => _VirtualizedPaintPageState();
}

class _VirtualizedPaintPageState extends State<_VirtualizedPaintPage> {
  final controller = ScrollController();
  final liveCards = <_VirtualizedPaintCardState>{};

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: const ScrollBehavior().copyWith(scrollbars: false),
    child: CustomScrollView(
      controller: controller,
      slivers: [
        InactiveFeedSliver(
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisExtent: 100,
            ),
            itemCount: 100,
            itemBuilder: (_, index) => _VirtualizedPaintCard(
              bytes: widget.bytes,
              live: liveCards,
            ),
          ),
        ),
      ],
    ),
  );
}

class _VirtualizedPaintCard extends StatefulWidget {
  const _VirtualizedPaintCard({required this.bytes, required this.live});

  final Uint8List bytes;
  final Set<_VirtualizedPaintCardState> live;

  @override
  State<_VirtualizedPaintCard> createState() => _VirtualizedPaintCardState();
}

class _VirtualizedPaintCardState extends State<_VirtualizedPaintCard> {
  @override
  void initState() {
    super.initState();
    widget.live.add(this);
  }

  @override
  void dispose() {
    widget.live.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode.valuesOf(context).enabled
      ? Image.memory(widget.bytes, fit: BoxFit.fill)
      : const SizedBox.expand();
}

void main() {
  for (final (releaseContents, externalContent, lateCleanup) in [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (true, false, true),
  ]) {
    final shouldRelease = releaseContents && !externalContent;
    testWidgets(
      lateCleanup
          ? 'initially inactive cleanup releases a reparented retained subtree'
          : externalContent
          ? 'cleanup leaves a subtree containing external textures intact'
          : releaseContents
          ? 'releasing layer contents preserves state, scroll and restored pixels'
          : 'hidden image handles dispose while detached Pictures retain pixels',
      (tester) async {
        final bytes = await tester.runAsync(_redPng);
        final cache = PaintingBinding.instance.imageCache;
        final previousMaximumSize = cache.maximumSize;
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = 0;

        final previousCreate = ui.Image.onCreate;
        final previousDispose = ui.Image.onDispose;
        var openImageHandles = 0;
        ui.Image.onCreate = (image) {
          previousCreate?.call(image);
          openImageHandles++;
        };
        ui.Image.onDispose = (image) {
          previousDispose?.call(image);
          openImageHandles--;
        };
        addTearDown(() {
          ui.Image.onCreate = previousCreate;
          ui.Image.onDispose = previousDispose;
          cache
            ..clear()
            ..clearLiveImages()
            ..maximumSize = previousMaximumSize;
        });

        final pageKey = GlobalKey<_RetainedPageState>();
        final cellKey = GlobalKey();
        final rootKey = GlobalKey();
        Widget scene(bool active, {bool? visible}) {
          Widget page = _RetainedPage(
            key: pageKey,
            bytes: bytes!,
            cellKey: cellKey,
            externalContent: externalContent,
          );
          if (releaseContents && (!lateCleanup || !active)) {
            page = InactivePaintCleanup(child: page);
          }
          return Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: rootKey,
              child: TickerMode(
                enabled: active,
                child: Offstage(offstage: !(visible ?? active), child: page),
              ),
            ),
          );
        }

        Future<void> settleImage() async {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(scene(true));
        await settleImage();
        final state = pageKey.currentState!;
        state.controller.jumpTo(50);
        await tester.pump();
        await settleImage();
        expect(find.byType(RawImage), findsWidgets);
        expect(openImageHandles, greaterThan(0));

        final boundary =
            cellKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final oldPictures = _pictures(boundary.debugLayer!);
        expect(oldPictures, isNotEmpty);
        final root =
            rootKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final before = await tester.runAsync(
          () async => _pixels(await root.toImage(pixelRatio: 1)),
        );

        // 模拟 PageView 已将页面移入保活桶，随后活动通知才卸载图像。
        // 若同一帧隐藏和卸载，flushPaint 会先重画深层边界，旧图可正常释放。
        await tester.pumpWidget(scene(true, visible: false));
        expect(boundary.debugLayer!.attached, isFalse);
        await tester.pumpWidget(scene(false));
        await tester.pump();
        expect(find.byType(RawImage, skipOffstage: false), findsNothing);
        expect(cache.liveImageCount, 0);
        expect(cache.currentSizeBytes, 0);
        expect(openImageHandles, 0);
        expect(pageKey.currentState, same(state));
        expect(state.controller.offset, 50);

        if (shouldRelease) {
          expect(oldPictures.every((picture) => picture.debugDisposed), isTrue);
        } else {
          expect(
            oldPictures.every((picture) => !picture.debugDisposed),
            isTrue,
          );
          expect(boundary.debugLayer!.attached, isFalse);
          // 所有 Dart ui.Image 句柄已释放，旧 display list 仍可画出源图像。
          final retainedPixels = await tester.runAsync(
            () async => _pixels(await oldPictures.single.toImage(1, 1)),
          );
          expect(retainedPixels, orderedEquals([255, 0, 0, 255]));
        }

        await tester.pumpWidget(scene(true));
        await settleImage();
        expect(pageKey.currentState, same(state));
        expect(state.controller.offset, 50);
        expect(find.byType(RawImage), findsWidgets);
        final restored = await tester.runAsync(
          () async => _pixels(await root.toImage(pixelRatio: 1)),
        );
        expect(restored, orderedEquals(before!));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(oldPictures.every((picture) => picture.debugDisposed), isTrue);
        expect(openImageHandles, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
  for (final releaseContents in [false, true]) {
    testWidgets(
      'real TabActivity ${releaseContents ? 'on Windows releases' : 'on Android retains'} old image Pictures',
      (tester) async {
        final bytes = await tester.runAsync(_redPng);
        final cache = PaintingBinding.instance.imageCache;
        final previousMaximumSize = cache.maximumSize;
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = 0;
        addTearDown(() {
          cache
            ..clear()
            ..clearLiveImages()
            ..maximumSize = previousMaximumSize;
        });

        final controller = TabController(
          length: 3,
          vsync: tester,
          animationDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);
        final pageKey = GlobalKey<_RetainedPageState>();
        final cellKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TabBarView(
              controller: controller,
              children: [
                TabActivity(
                  controller: controller,
                  index: 0,
                  child: _RetainedPage(
                    key: pageKey,
                    bytes: bytes!,
                    cellKey: cellKey,
                  ),
                ),
                const SizedBox(),
                const SizedBox(),
              ],
            ),
          ),
        );
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        final state = pageKey.currentState!;
        state.controller.jumpTo(50);
        await tester.pumpAndSettle();
        final boundary =
            cellKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final oldPictures = _pictures(boundary.debugLayer!);
        expect(oldPictures, isNotEmpty);

        controller.animateTo(2);
        await tester.pumpAndSettle();
        await tester.pump();
        expect(find.byType(RawImage, skipOffstage: false), findsNothing);
        expect(cache.liveImageCount, 0);
        expect(cache.currentSizeBytes, 0);
        expect(pageKey.currentState, same(state));
        expect(state.controller.offset, 50);
        expect(
          oldPictures.every((picture) => picture.debugDisposed),
          releaseContents,
        );

        controller.animateTo(0);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
        expect(find.byType(RawImage), findsWidgets);
        expect(pageKey.currentState, same(state));
        expect(state.controller.offset, 50);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(oldPictures.every((picture) => picture.debugDisposed), isTrue);
      },
      variant: TargetPlatformVariant.only(
        releaseContents ? TargetPlatform.windows : TargetPlatform.android,
      ),
    );
  }

  testWidgets(
    'detached scene rebuild disposes native engine handles and restores pixels',
    (tester) async {
      final bytes = await tester.runAsync(_redPng);
      final cache = PaintingBinding.instance.imageCache;
      final previousMaximumSize = cache.maximumSize;
      cache
        ..clear()
        ..clearLiveImages()
        ..maximumSize = 0;
      addTearDown(() {
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = previousMaximumSize;
      });
      final pageKey = GlobalKey<_RetainedPageState>();
      final cellKey = GlobalKey();
      final outerKey = GlobalKey();
      final prototypeKey = GlobalKey();
      final screenshotKey = GlobalKey();
      Widget scene({required bool active, required bool visible}) =>
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: screenshotKey,
              child: Offstage(
                offstage: !visible,
                child: _TrackedBoundary(
                  key: outerKey,
                  child: RetainedLayerCleanupPrototype(
                    key: prototypeKey,
                    child: TickerMode(
                      enabled: active,
                      child: _RetainedPage(
                        key: pageKey,
                        bytes: bytes!,
                        cellKey: cellKey,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
      Future<void> settleImage() async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(scene(active: true, visible: true));
      await settleImage();
      final state = pageKey.currentState!;
      state.controller.jumpTo(50);
      await tester.pumpAndSettle();
      final outer =
          outerKey.currentContext!.findRenderObject()!
              as _RenderTrackedBoundary;
      final outerLayer = outer.debugLayer! as _TrackedOffsetLayer;
      final prototype =
          prototypeKey.currentContext!.findRenderObject()!
              as RenderRetainedLayerCleanupPrototype;
      final attachedEngineLayer = outerLayer.currentEngineLayer;
      expect(outerLayer.attached, isTrue);
      expect(prototype.release(), isTrue);
      // attached 的范围外祖先不参与临时合成，下一正常帧负责重画。
      expect(outerLayer.currentEngineLayer, same(attachedEngineLayer));
      await tester.pumpAndSettle();
      final screenshot =
          screenshotKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final before = await tester.runAsync(
        () async => _pixels(await screenshot.toImage(pixelRatio: 1)),
      );
      final boundary =
          cellKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final oldPictures = _pictures(boundary.debugLayer!);

      await tester.pumpWidget(scene(active: true, visible: false));
      await tester.pumpWidget(scene(active: false, visible: false));
      await tester.pump();
      expect(find.byType(RawImage, skipOffstage: false), findsNothing);
      expect(cache.liveImageCount, 0);
      expect(oldPictures.every((picture) => !picture.debugDisposed), isTrue);
      expect(outerLayer.attached, isFalse);
      final oldEngineLayer = outerLayer.currentEngineLayer!;
      final removeCompositionCallback = outerLayer.addCompositionCallback(
        (_) {},
      );
      expect(prototype.release(), isFalse);
      expect(oldPictures.every((picture) => !picture.debugDisposed), isTrue);
      expect(outerLayer.currentEngineLayer, same(oldEngineLayer));
      removeCompositionCallback();
      ui.Image? retainedNativeImage;
      expect(
        prototype.release(
          afterDartRelease: () {
            expect(
              oldPictures.every((picture) => picture.debugDisposed),
              isTrue,
            );
            final builder = ui.SceneBuilder()..addRetained(oldEngineLayer);
            final retainedScene = builder.build();
            retainedNativeImage = retainedScene.toImageSync(1, 1);
            retainedScene.dispose();
          },
        ),
        isTrue,
      );
      final nativePixels = await tester.runAsync(
        () => _pixels(retainedNativeImage!),
      );
      expect(nativePixels, orderedEquals([255, 0, 0, 255]));
      expect(outerLayer.currentEngineLayer, isNot(same(oldEngineLayer)));
      // EngineLayer 没有 debugDisposed。其 dispose 在已释放时先断言，
      // 因此这里验证的是框架已清掉 native handle，不会重复执行释放。
      expect(
        oldEngineLayer.dispose,
        throwsA(
          isA<AssertionError>().having(
            (error) => error.message,
            'disposed native handle',
            'Object disposed',
          ),
        ),
      );

      await tester.pumpWidget(scene(active: true, visible: true));
      await settleImage();
      final restored = await tester.runAsync(
        () async => _pixels(await screenshot.toImage(pixelRatio: 1)),
      );
      expect(restored, orderedEquals(before!));
      expect(pageKey.currentState, same(state));
      expect(state.controller.offset, 50);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  for (final strategy in [
    'normal',
    'none',
    'followup',
    'scope',
    'root',
    'production',
  ]) {
    testWidgets(
      'attached cleanup then offstage: $strategy',
      (tester) async {
        final bytes = await tester.runAsync(_redPng);
        final cache = PaintingBinding.instance.imageCache;
        final previousMaximumSize = cache.maximumSize;
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = 0;
        addTearDown(() {
          cache
            ..clear()
            ..clearLiveImages()
            ..maximumSize = previousMaximumSize;
        });
        final pageKey = GlobalKey<_RetainedPageState>();
        final outerKey = GlobalKey();
        final prototypeKey = GlobalKey();
        final screenshotKey = GlobalKey();
        final cellKey = GlobalKey();
        Widget scene({
          required bool active,
          required bool visible,
          required bool showImages,
        }) => Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: screenshotKey,
            child: Stack(
              children: [
                Offstage(
                  offstage: !visible,
                  child: _TrackedBoundary(
                    key: outerKey,
                    child: TickerMode(
                      enabled: active,
                      child: Builder(
                        builder: (_) {
                          final probe = RetainedLayerCleanupPrototype(
                            key: prototypeKey,
                            child: _RetainedPage(
                              key: pageKey,
                              bytes: bytes!,
                              cellKey: cellKey,
                              showImagesOverride: showImages,
                            ),
                          );
                          return strategy == 'production'
                              ? InactivePaintCleanup(child: probe)
                              : probe;
                        },
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  top: 0,
                  left: 0,
                  width: 8,
                  height: 8,
                  child: ColoredBox(color: ui.Color(0xff0000ff)),
                ),
              ],
            ),
          ),
        );
        Future<void> settleImage() async {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          scene(active: true, visible: true, showImages: true),
        );
        await settleImage();
        final state = pageKey.currentState!;
        final screenshot =
            screenshotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final before = await tester.runAsync(
          () async => _pixels(
            await screenshot.toImage(pixelRatio: 1),
          ),
        );
        await tester.pumpWidget(
          scene(
            active: false,
            visible: true,
            showImages: strategy != 'normal',
          ),
        );
        final outer =
            outerKey.currentContext!.findRenderObject()!
                as _RenderTrackedBoundary;
        final outerLayer = outer.debugLayer! as _TrackedOffsetLayer;
        final prototype =
            prototypeKey.currentContext!.findRenderObject()!
                as RenderRetainedLayerCleanupPrototype;
        expect(outerLayer.attached, isTrue);
        if (strategy != 'production') expect(prototype.release(), isTrue);
        final oldEngineLayer = outerLayer.currentEngineLayer!;
        if (strategy == 'scope' || strategy == 'root') {
          expect(
            prototype.release(
              recomposeAttachedScopes: true,
              recomposeAttachedRoots: strategy == 'root',
            ),
            isTrue,
          );
        }
        var followups = 0;
        if (strategy == 'followup') {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (prototype.attached) {
              prototype.release();
              followups++;
            }
          });
        }
        await tester.pumpWidget(
          scene(active: false, visible: false, showImages: false),
        );
        expect(find.byType(RawImage, skipOffstage: false), findsNothing);
        expect(cache.liveImageCount, 0);
        expect(outerLayer.attached, isFalse);
        if (strategy == 'root' ||
            strategy == 'followup' ||
            strategy == 'production') {
          expect(
            oldEngineLayer.dispose,
            throwsA(
              isA<AssertionError>().having(
                (error) => error.message,
                'disposed native handle',
                'Object disposed',
              ),
            ),
          );
        } else {
          expect(outerLayer.currentEngineLayer, same(oldEngineLayer));
          if (strategy != 'scope') {
            // scope-only 重建会使旧父层的 debug children 标为 usedAsOldLayer，
            // addRetained 在 debug 模式因此拒绝它；其父 native handle 仍未释放。
            final retained = (ui.SceneBuilder()..addRetained(oldEngineLayer))
                .build();
            final pixels = await tester.runAsync(
              () => _pixels(retained.toImageSync(1, 1)),
            );
            retained.dispose();
            expect(
              pixels,
              orderedEquals(
                strategy == 'normal' ? [0, 0, 0, 0] : [255, 0, 0, 255],
              ),
            );
          }
        }
        if (strategy == 'followup') expect(followups, 1);
        await tester.pumpAndSettle();
        if (strategy == 'followup') expect(followups, 1);
        await tester.pumpWidget(
          scene(active: true, visible: true, showImages: true),
        );
        await settleImage();
        final restored = await tester.runAsync(
          () async => _pixels(
            await screenshot.toImage(pixelRatio: 1),
          ),
        );
        expect(restored, orderedEquals(before!));
        expect(pageKey.currentState, same(state));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'production cleanup cancels a stale followup across resume and rehide',
    (tester) async {
      final outerKey = GlobalKey();
      final innerKey = GlobalKey();
      Widget scene({required bool active, required bool visible}) =>
          Directionality(
            textDirection: TextDirection.ltr,
            child: Offstage(
              offstage: !visible,
              child: _TrackedBoundary(
                key: outerKey,
                child: TickerMode(
                  enabled: active,
                  child: InactivePaintCleanup(
                    child: _TrackedBoundary(
                      key: innerKey,
                      child: const SizedBox.expand(
                        child: ColoredBox(color: ui.Color(0xffff0000)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
      await tester.pumpWidget(scene(active: true, visible: true));
      await tester.pumpWidget(scene(active: false, visible: true));
      final outer =
          outerKey.currentContext!.findRenderObject()!
              as _RenderTrackedBoundary;
      final layer = outer.debugLayer! as _TrackedOffsetLayer;
      final initialUpdates = layer.engineUpdates;

      void buildWithoutCompletingFrame(Widget widget) {
        final binding = tester.binding;
        binding.attachRootWidget(binding.wrapWithDefaultView(widget));
        binding.buildOwner!.buildScope(binding.rootElement!);
      }

      // 在旧 followup 执行前实际重建两次，让 render object 观察到新代次。
      buildWithoutCompletingFrame(scene(active: true, visible: true));
      buildWithoutCompletingFrame(scene(active: false, visible: true));
      await tester.pumpWidget(scene(active: false, visible: false));
      // 旧代次 followup 已取消；这里只执行新代次的首遍清理。
      expect(layer.engineUpdates, initialUpdates + 1);
      await tester.pump();
      // 新代次也只补一遍。
      expect(layer.engineUpdates, initialUpdates + 2);
      await tester.pumpAndSettle();
      expect(layer.engineUpdates, initialUpdates + 2);
      await tester.pumpWidget(scene(active: true, visible: true));
      await tester.pumpAndSettle();
      expect(find.byType(ColoredBox), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final (nestedPageView, nearestOnly, external) in [
    (false, false, 'none'),
    (false, false, 'texture'),
    (false, false, 'platform'),
    (false, false, 'callback'),
    (true, true, 'none'),
    (true, false, 'none'),
  ]) {
    testWidgets(
      'bounded hidden ancestors: pageView=$nestedPageView nearest=$nearestOnly external=$external',
      (tester) async {
        final bytes = await tester.runAsync(_redPng);
        final cache = PaintingBinding.instance.imageCache;
        final previousMaximumSize = cache.maximumSize;
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = 0;
        addTearDown(() {
          cache
            ..clear()
            ..clearLiveImages()
            ..maximumSize = previousMaximumSize;
        });
        final pageKey = GlobalKey<_RetainedPageState>();
        final cellKey = GlobalKey();
        final routeKey = GlobalKey();
        final prototypeKey = GlobalKey();
        final globalKey = GlobalKey();
        final pageController = PageController();
        addTearDown(pageController.dispose);
        Widget scene({required bool active, required bool visible}) {
          final page = TickerMode(
            enabled: active,
            child: RetainedLayerCleanupPrototype(
              key: prototypeKey,
              child: ScrollConfiguration(
                behavior: const ScrollBehavior().copyWith(scrollbars: false),
                child: _RetainedPage(
                  key: pageKey,
                  bytes: bytes!,
                  cellKey: cellKey,
                ),
              ),
            ),
          );
          return Directionality(
            textDirection: TextDirection.ltr,
            child: _TrackedBoundary(
              key: globalKey,
              child: Stack(
                children: [
                  Offstage(
                    offstage: !visible,
                    child: _TrackedBoundary(
                      key: routeKey,
                      child: Stack(
                        children: [
                          if (nestedPageView)
                            PageView(
                              controller: pageController,
                              children: [
                                page,
                                const SizedBox(),
                                const ColoredBox(color: ui.Color(0xff00ff00)),
                              ],
                            )
                          else
                            page,
                          const Positioned(
                            top: 0,
                            right: 0,
                            width: 8,
                            height: 8,
                            child: ColoredBox(color: ui.Color(0xff0000ff)),
                          ),
                          if (external == 'texture')
                            const Positioned(
                              top: 16,
                              right: 0,
                              width: 8,
                              height: 8,
                              child: Texture(textureId: 1),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 可见播放分支在明确隐藏边界之外，不能被临时重建或阻止清理。
                  const Positioned(
                    left: 0,
                    top: 0,
                    width: 8,
                    height: 8,
                    child: Texture(textureId: 2),
                  ),
                ],
              ),
            ),
          );
        }

        Future<void> settleImage() async {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(scene(active: true, visible: true));
        await settleImage();
        final page = pageKey.currentState!;
        page.controller.jumpTo(50);
        await tester.pumpAndSettle();
        final position = page.controller.position;
        final global =
            globalKey.currentContext!.findRenderObject()!
                as _RenderTrackedBoundary;
        final before = await tester.runAsync(
          () async => _pixels(await global.toImage(pixelRatio: 1)),
        );
        await tester.pumpWidget(scene(active: true, visible: false));
        final route =
            routeKey.currentContext!.findRenderObject()!
                as _RenderTrackedBoundary;
        final routeLayer = route.debugLayer! as _TrackedOffsetLayer;
        expect(routeLayer.parent, isNull);
        expect(routeLayer.attached, isFalse);
        // 本例普通 Offstage 会 detach。使用独立 owner 单独验证“已离开可见
        // Scene，但 Dart layer 仍 attached”的拓扑，不把它伪称为真实路由复现。
        // 没有把隐藏层 graft 回全局树，也不重建可见全局根。
        routeLayer.attach(Object());
        VoidCallback? removeCallback;
        try {
          if (nestedPageView) pageController.jumpToPage(2);
          await tester.pumpWidget(scene(active: false, visible: false));
          await tester.pumpAndSettle();
          expect(pageKey.currentState, same(page));
          expect(page.controller.position, same(position));
          expect(position.pixels, 50);
          expect(find.byType(RawImage, skipOffstage: false), findsNothing);
          expect(cache.liveImageCount, 0);
          expect(cache.currentSizeBytes, 0);
          expect(routeLayer.attached, isTrue);
          final oldRouteEngine = routeLayer.currentEngineLayer!;
          final retainedScene = (ui.SceneBuilder()..addRetained(oldRouteEngine))
              .build();
          final retainedPixels = await tester.runAsync(
            () => _pixels(retainedScene.toImageSync(1, 1)),
          );
          retainedScene.dispose();
          expect(retainedPixels, orderedEquals([255, 0, 0, 255]));
          final prototype =
              prototypeKey.currentContext!.findRenderObject()!
                  as RenderRetainedLayerCleanupPrototype;
          if (nestedPageView) {
            var keptAliveAncestor = false;
            for (
              RenderObject? node = prototype;
              node != null;
              node = node.parent
            ) {
              final data = node.parentData;
              if (data is SliverMultiBoxAdaptorParentData && data.keptAlive) {
                keptAliveAncestor = true;
              }
            }
            expect(keptAliveAncestor, isTrue);
          }
          // 原来只沿 detached Dart 父链重建的方案无法替换外层缓存句柄。
          expect(prototype.release(), isTrue);
          expect(routeLayer.currentEngineLayer, same(oldRouteEngine));
          if (external == 'platform') {
            routeLayer.append(
              PlatformViewLayer(
                rect: const Rect.fromLTWH(0, 0, 8, 8),
                viewId: 1,
              ),
            );
          } else if (external == 'callback') {
            removeCallback = routeLayer.addCompositionCallback((_) {});
          }
          final globalLayer = global.debugLayer! as _TrackedOffsetLayer;
          final oldGlobalEngine = globalLayer.currentEngineLayer;
          final globalUpdates = globalLayer.engineUpdates;
          final routeUpdates = routeLayer.engineUpdates;
          expect(
            prototype.release(
              recomposeHiddenAncestors: true,
              nearestHiddenBoundaryOnly: nearestOnly,
            ),
            external == 'none',
          );
          expect(globalLayer.engineUpdates, globalUpdates);
          expect(globalLayer.currentEngineLayer, same(oldGlobalEngine));
          if (external == 'none' && !nearestOnly) {
            expect(routeLayer.engineUpdates, routeUpdates + 1);
            expect(
              oldRouteEngine.dispose,
              throwsA(
                isA<AssertionError>().having(
                  (error) => error.message,
                  'disposed native handle',
                  'Object disposed',
                ),
              ),
            );
            final rebuiltScene =
                (ui.SceneBuilder()..addRetained(routeLayer.currentEngineLayer!))
                    .build();
            final clearedPixels = await tester.runAsync(
              () => _pixels(rebuiltScene.toImageSync(1, 1)),
            );
            rebuiltScene.dispose();
            expect(
              clearedPixels,
              orderedEquals(
                nestedPageView ? [0, 255, 0, 255] : [0, 0, 0, 0],
              ),
            );
          } else {
            expect(routeLayer.engineUpdates, routeUpdates);
            expect(routeLayer.currentEngineLayer, same(oldRouteEngine));
          }
        } finally {
          removeCallback?.call();
          if (routeLayer.attached && routeLayer.parent == null) {
            routeLayer.detach();
          }
        }
        if (nestedPageView) pageController.jumpToPage(0);
        await tester.pumpWidget(scene(active: true, visible: true));
        await settleImage();
        final restored = await tester.runAsync(
          () async => _pixels(await global.toImage(pixelRatio: 1)),
        );
        expect(restored, orderedEquals(before!));
        expect(pageKey.currentState, same(page));
        expect(page.controller.position, same(position));
        expect(position.pixels, 50);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final strategy in ['original', 'recursive', 'production']) {
    final recursive = strategy != 'original';
    final production = strategy == 'production';
    testWidgets(
      'viewport retained clip survives card disposal: $strategy',
      (tester) async {
        final bytes = await tester.runAsync(_redPng);
        final cache = PaintingBinding.instance.imageCache;
        final previousMaximumSize = cache.maximumSize;
        cache
          ..clear()
          ..clearLiveImages()
          ..maximumSize = 0;
        addTearDown(() {
          cache
            ..clear()
            ..clearLiveImages()
            ..maximumSize = previousMaximumSize;
        });
        final pageKey = GlobalKey<_VirtualizedPaintPageState>();
        final prototypeKey = GlobalKey();
        final screenshotKey = GlobalKey();
        Widget scene({required bool active, required bool visible}) =>
            Directionality(
              textDirection: TextDirection.ltr,
              child: RepaintBoundary(
                key: screenshotKey,
                child: Offstage(
                  offstage: !visible,
                  child: TickerMode(
                    enabled: active,
                    child: Builder(
                      builder: (_) {
                        final page = RetainedLayerCleanupPrototype(
                          key: prototypeKey,
                          child: _VirtualizedPaintPage(
                            key: pageKey,
                            bytes: bytes!,
                          ),
                        );
                        return production
                            ? InactivePaintCleanup(child: page)
                            : page;
                      },
                    ),
                  ),
                ),
              ),
            );
        Future<void> settleImage() async {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(scene(active: true, visible: true));
        await settleImage();
        final page = pageKey.currentState!;
        page.controller.jumpTo(50);
        await tester.pumpAndSettle();
        final position = page.controller.position;
        final viewport = tester.renderObject<RenderViewport>(
          find.byType(Viewport),
        );
        final viewportLayer = viewport.debugLayer!;
        final clip = viewportLayer.firstChild! as ClipRectLayer;
        final oldPictures = _pictures(clip);
        expect(oldPictures.length, greaterThan(4));
        final cardCount = page.liveCards.length;
        expect(cardCount, greaterThan(4));
        final oldCard = page.liveCards.last.context.findRenderObject()!;
        final screenshot =
            screenshotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final before = await tester.runAsync(
          () async => _pixels(await screenshot.toImage(pixelRatio: 1)),
        );

        await tester.pumpWidget(scene(active: true, visible: false));
        await tester.pumpWidget(scene(active: false, visible: false));
        await tester.pumpAndSettle();
        expect(page.liveCards, hasLength(4));
        expect(oldCard.debugDisposed, isTrue);
        expect(find.byType(RawImage, skipOffstage: false), findsNothing);
        expect(cache.liveImageCount, 0);
        expect(cache.currentSizeBytes, 0);
        expect(clip.attached, isFalse);
        expect(clip.debugDisposed, isFalse);
        final prototype =
            prototypeKey.currentContext!.findRenderObject()!
                as RenderRetainedLayerCleanupPrototype;
        if (!production) {
          expect(
            _pictures(clip).any((picture) => !picture.debugDisposed),
            isTrue,
          );
          expect(
            prototype.release(recursiveScopeContainers: recursive),
            isTrue,
          );
        }
        expect(viewportLayer.firstChild, isNull);
        expect(clip.parent, isNull);
        expect(clip.debugDisposed, isFalse);
        final remainingPictures = oldPictures
            .where((picture) => !picture.debugDisposed)
            .toList();
        debugPrint(
          'viewport clip $strategy: cards=$cardCount -> 4; '
          'oldPictures=${oldPictures.length}; retained=${remainingPictures.length}; '
          'clipChildren=${clip.firstChild != null}',
        );
        if (recursive) {
          expect(remainingPictures, isEmpty);
          expect(clip.firstChild, isNull);
        } else {
          expect(remainingPictures, isNotEmpty);
          final retainedPixels = await tester.runAsync(
            () async => _pixels(await remainingPictures.first.toImage(1, 1)),
          );
          expect(retainedPixels, orderedEquals([255, 0, 0, 255]));
          // 再次沿当前 RenderObject 树清理也找不到已成为孤岛的内部 Clip。
          expect(prototype.release(), isTrue);
          expect(
            remainingPictures.any((picture) => !picture.debugDisposed),
            isTrue,
          );
        }
        await tester.pumpWidget(scene(active: true, visible: true));
        await settleImage();
        final restored = await tester.runAsync(
          () async => _pixels(await screenshot.toImage(pixelRatio: 1)),
        );
        expect(restored, orderedEquals(before!));
        expect(pageKey.currentState, same(page));
        expect(page.controller.position, same(position));
        expect(position.pixels, 50);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
