import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/pages/video/pay_coins/view.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../../support/memory_box.dart';

Finder asset(String path) => find.byWidgetPredicate((widget) {
  if (widget is! Image) return false;
  final provider = widget.image;
  final image = provider is ResizeImage ? provider.imageProvider : provider;
  return image is AssetImage && image.assetName == path;
});

Finder semantics(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Future<void> decodeImages(WidgetTester tester) async {
  // 图片解码运行在真实异步队列；只推进少量测试时钟，保留动画中途断言。
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<void> openPage(
  WidgetTester tester,
  List<(int, bool)> calls, {
  bool hasCoin = false,
  bool hasCopyright = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    GetMaterialApp(
      home: Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => PayCoinsPage.toPayCoinsPage(
              onPayCoin: (count, like) => calls.add((count, like)),
              hasCoin: hasCoin,
              hasCopyright: hasCopyright,
            ),
            child: const Text('打开投币'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开投币'));
  await tester.pumpAndSettle();
  await decodeImages(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
  });
  setUp(() async {
    Get.testMode = true;
    GlobalData().coins = 10;
    await GStorage.setting.clear();
  });
  tearDown(() {
    GlobalData().coins = null;
    Get.reset();
  });

  test('抛币 GIF 各播放一次，帧时长与页面完成回调一致', () async {
    for (final path in [Assets.coinTossOne, Assets.coinTossTwo]) {
      final bytes = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
      expect(codec.frameCount, greaterThan(1));
      expect(codec.repetitionCount, 0);
      var duration = Duration.zero;
      for (var i = 0; i < codec.frameCount; i++) {
        final frame = await codec.getNextFrame();
        duration += frame.duration;
        frame.image.dispose();
      }
      expect(duration, const Duration(milliseconds: 960));
      codec.dispose();
    }
  });

  for (final count in [1, 2]) {
    testWidgets('上滑播放 $count 枚动画后回调一次，保留同时点赞', (tester) async {
      final calls = <(int, bool)>[];
      await GStorage.setting.put(SettingBoxKey.coinWithLike, true);
      await openPage(tester, calls);
      if (count == 2) {
        await tester.tap(asset(Assets.right));
        await tester.pumpAndSettle();
      }
      expect(
        asset(count == 1 ? Assets.coinsReadyOne : Assets.coinsReadyTwo),
        findsOneWidget,
      );
      await tester.drag(
        semantics('上滑投$count枚硬币'),
        const Offset(0, -65),
      );
      await decodeImages(tester);
      expect(semantics('正在投币'), findsOneWidget);
      final animation = tester.widget<Image>(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is MemoryImage,
        ),
      );
      expect(animation.image, isA<MemoryImage>());
      await tester.tap(semantics('正在投币'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, [(count, true)]);
      expect(find.byType(PayCoinsPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('余额不足及已投一枚时限制双币', (tester) async {
    final calls = <(int, bool)>[];
    GlobalData().coins = 1;
    await openPage(tester, calls, hasCoin: true);
    await tester.tap(asset(Assets.right));
    await tester.pumpAndSettle();
    expect(asset(Assets.coinsEmpty), findsOneWidget);
    await tester.drag(asset(Assets.coinsEmpty), const Offset(0, -65));
    await tester.pump(const Duration(seconds: 2));
    expect(calls, isEmpty);
    expect(find.text('暂时无法投币'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('零余额显示空币槽，点击和上滑均不提交', (tester) async {
    final calls = <(int, bool)>[];
    GlobalData().coins = 0;
    await openPage(tester, calls);
    await tester.tap(asset(Assets.coinsEmpty));
    await tester.drag(asset(Assets.coinsEmpty), const Offset(0, -65));
    await tester.pump(const Duration(seconds: 2));
    expect(calls, isEmpty);
    expect(find.byType(PayCoinsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非原创视频保持单币入口，点击可投币', (tester) async {
    final calls = <(int, bool)>[];
    await openPage(tester, calls, hasCopyright: false);
    expect(find.byType(PageView), findsNothing);
    await tester.tap(semantics('上滑投1枚硬币'));
    await decodeImages(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, [(1, false)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放中关闭取消回调，再次打开从首帧播放', (tester) async {
    final calls = <(int, bool)>[];
    await openPage(tester, calls);
    await tester.tap(semantics('上滑投1枚硬币'));
    await decodeImages(tester);
    final first = tester
        .widget<Image>(
          find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is MemoryImage,
          ),
        )
        .image;
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(asset(Assets.panelClose));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, isEmpty);
    await tester.tap(find.text('打开投币'));
    await tester.pumpAndSettle();
    await tester.tap(semantics('上滑投1枚硬币'));
    await decodeImages(tester);
    final second = tester
        .widget<Image>(
          find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is MemoryImage,
          ),
        )
        .image;
    expect(second, isNot(first));
    expect(calls, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, [(1, false)]);
    expect(tester.takeException(), isNull);
  });
}
