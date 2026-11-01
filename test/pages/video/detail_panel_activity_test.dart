import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/pages/video/widgets/detail_panels.dart';

class _AnimationCache implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    yield FileInfo(
      File('test/common/widgets/image/fixtures/animated.webp'),
      FileSource.Cache,
      DateTime(2100),
      url,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'fullscreen releases hidden images and restores retained panels',
    (
      tester,
    ) async {
      final cache = PaintingBinding.instance.imageCache;
      final manager = _AnimationCache();
      final panelKey = GlobalKey();
      final panel = StatefulBuilder(
        key: panelKey,
        builder: (_, _) => CachedImage(
          imageUrl: 'https://example.test/fullscreen-animation.webp',
          cacheManager: manager,
          width: 64,
          height: 64,
          memCacheWidth: 64,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
        ),
      );

      Future<void> advance() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> show({required bool fullscreen, bool active = true}) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TickerMode(
              enabled: active,
              child: VideoDetailOffstage(offstage: fullscreen, child: panel),
            ),
          ),
        );
        await advance();
      }

      try {
        await show(fullscreen: false);
        final state = panelKey.currentState;
        expect(state, isNotNull);
        expect(cache.liveImageCount, 1);
        expect(find.byType(RawImage), findsOneWidget);

        await show(fullscreen: true);
        expect(panelKey.currentState, same(state));
        expect(cache.liveImageCount, 0);
        expect(find.byType(RawImage, skipOffstage: false), findsNothing);

        await show(fullscreen: false);
        expect(panelKey.currentState, same(state));
        expect(cache.liveImageCount, 1);
        expect(find.byType(RawImage), findsOneWidget);

        await show(fullscreen: false, active: false);
        expect(cache.liveImageCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        cache
          ..clear()
          ..clearLiveImages();
        tester.binding.scheduleFrame();
        await tester.pump();
        await advance();
      }
    },
  );
}
