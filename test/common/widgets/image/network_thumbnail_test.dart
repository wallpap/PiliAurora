import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../../support/memory_box.dart';

void main() {
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>({SettingBoxKey.defaultPicQa: 80});
    GStorage.localCache = MemoryBox<dynamic>();
  });

  testWidgets(
    'cards preserve animation sources until the decoder knows their aspect ratio',
    (
      tester,
    ) async {
      late CachedImage image;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: Builder(
            builder: (context) {
              // 检查生产卡片生成的请求，避免发出真实下载。
              final built = const NetworkImgLayer(
                src: 'https://i0.hdslb.com/bfs/new_dyn/animation.gif',
                width: 400,
                height: 164.5,
              ).build(context) as ClipRRect;
              image = built.child! as CachedImage;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(image.memCacheHeight, 329);
      expect(
        image.imageUrl,
        'https://i0.hdslb.com/bfs/new_dyn/animation.gif@80q.webp',
      );
      expect(image.decodeTarget, isNotNull);
      expect(image.imageUrl, endsWith('q.webp'));
      expect(image.maxDecodePixels, 1 << 20);
    },
  );

  test('thumbnail sizing preserves crop options and the pixel budget', () {
    final url = ImageUtils.thumbnailUrlForSize(
      'https://i0.hdslb.com/bfs/new_dyn/animation.webp',
      width: 171,
    );
    expect(url, contains('@171w_4096h_'));
    const cropped =
        'https://i0.hdslb.com/bfs/face/avatar.png@800w_800h_200p_1e_1c.webp';
    expect(
      ImageUtils.thumbnailUrlForSize(cropped, width: 171),
      'https://i0.hdslb.com/bfs/face/avatar.png@800w_800h_200p_1e_1c_80q.webp',
    );
    final large = ImageUtils.thumbnailUrlForSize(
      'https://i0.hdslb.com/bfs/new_dyn/animation.webp',
      width: 2048,
      height: 2048,
    );
    expect(large, contains('@1024w_1024h_'));
  });

  testWidgets(
    'degenerate display or source geometry creates no invalid decode target',
    (tester) async {
      for (final source in [
        const Size(1600, 400),
        const Size(double.infinity, 400),
        const Size(.5, .5),
      ]) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(),
            child: Builder(
              builder: (context) {
                final layer = NetworkImgLayer(
                  src: 'https://example.test/cover.png',
                  width: 0,
                  height: 0,
                  sourceSize: source,
                ).build(context) as ClipRRect;
                expect((layer.child! as CachedImage).decodeTarget, isNull);
                return const SizedBox();
              },
            ),
          ),
        );
      }
    },
  );

  test('original quality and other hosts keep their existing URLs', () {
    for (final src in [
      'https://example.test/image.gif',
      'https://nothdslb.com/bfs/image.gif',
      'https://i0.hdslb.com/bfs/image.gif?key=value',
    ]) {
      expect(
        ImageUtils.thumbnailUrlForSize(src, width: 171),
        '$src@80q.webp',
      );
    }
    const src = 'https://i0.hdslb.com/bfs/new_dyn/animation.gif';
    expect(ImageUtils.thumbnailUrlForSize(src, quality: 100, width: 171), src);
    expect(ImageUtils.thumbnailUrlForSize(src), '$src@80q.webp');
  });
}
