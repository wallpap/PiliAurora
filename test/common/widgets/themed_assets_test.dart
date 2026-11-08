import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/common/theme/app_icon_style.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

String imageAsset(Image image) => switch (image.image) {
  AssetImage(:final assetName) => assetName,
  ResizeImage(imageProvider: AssetImage(:final assetName)) => assetName,
  _ => '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());

  test('图标和通用明暗资源均可从 bundle 加载，位图与 SVG 可解码', () async {
    for (final brightness in Brightness.values) {
      final images = {
        for (final style in AppIconStyle.values)
          Assets.iconImage(style, brightness),
        for (final asset in [
          Assets.loading,
          Assets.ai,
          Assets.avatarPlaceHolder,
          Assets.topicHeader,
        ])
          Assets.themed(asset, brightness),
      };
      for (final path in images) {
        final data = await rootBundle.load(path);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: path);
        expect(frame.image.height, greaterThan(0), reason: path);
        frame.image.dispose();
        codec.dispose();
      }
      if (Platform.isWindows) {
        for (final style in AppIconStyle.values) {
          final path = Assets.iconIco(style, brightness);
          expect(
            (await rootBundle.load(path)).lengthInBytes,
            greaterThan(0),
            reason: path,
          );
        }
      }
      for (final asset in [Assets.error, Assets.vipIcon]) {
        final path = Assets.themed(asset, brightness);
        final picture = await vg.loadPicture(
          SvgStringLoader(await rootBundle.loadString(path)),
          null,
        );
        expect(picture.size.isEmpty, isFalse, reason: path);
        picture.picture.dispose();
      }
    }
  });

  testWidgets('切换主题后占位和头像实时更新，空状态重试仍可用', (tester) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    var retries = 0;
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: brightness,
        builder: (context, value, child) => MaterialApp(
          theme: ThemeData(brightness: value),
          home: Scaffold(
            body: Column(
              children: [
                const NetworkImgLayer(src: null, width: 180, height: 100),
                const NetworkImgLayer(
                  src: null,
                  width: 48,
                  height: 48,
                  type: ImageType.avatar,
                ),
                HttpError(
                  isSliver: false,
                  safeArea: false,
                  onReload: () => retries++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    List<String> paths() =>
        tester.widgetList<Image>(find.byType(Image)).map(imageAsset).toList();
    expect(paths(), containsAll([Assets.loading, Assets.avatarPlaceHolder]));
    for (final value in [Brightness.dark, Brightness.light]) {
      brightness.value = value;
      await tester.pumpAndSettle();
      expect(
        paths(),
        containsAll([
          Assets.themed(Assets.loading, value),
          Assets.themed(Assets.avatarPlaceHolder, value),
        ]),
      );
      await tester.tap(find.text('点击重试'));
      expect(tester.takeException(), isNull);
    }
    expect(retries, 2);
  });
}
