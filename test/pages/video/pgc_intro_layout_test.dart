import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/video/video_tag/data.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/view.dart';

const _title = 'Re：从零开始的异世界生活 Memory Snow(雪之回忆)';

class _IntroController extends GetxController implements PgcIntroController {
  @override
  final pgcItem = PgcInfoModel.fromJson({
    'title': _title,
    'cover': '',
    'stat': {'views': 130000000, 'danmakus': 1320000},
    'rating': {'score': 7.2, 'count': 89000},
    'areas': [
      {'name': '日本'},
    ],
    'publish': {
      'release_date_show': '2025.01.02 22:00',
      'time_length_show': '已完结，全13话',
    },
  });

  @override
  bool get isPgc => true;

  @override
  final videoTags = Rx<List<VideoTagItem>?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoController extends GetxController implements VideoDetailController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(Get.reset);

  for (final width in [300.0, 600.0]) {
    testWidgets('PGC overview title and statistics fit a $width wide panel', (
      tester,
    ) async {
      Get
        ..put<PgcIntroController>(_IntroController(), tag: 'layout')
        ..put<VideoDetailController>(_VideoController(), tag: 'layout');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: CustomScrollView(
                  slivers: [
                    PgcIntroPage(
                      heroTag: 'layout',
                      showEpisodes: () {},
                      showIntroDetail: (_, _) {},
                      maxWidth: width,
                      isLandscape: false,
                      showHeader: false,
                      headerOnly: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final title = tester.renderObject<RenderParagraph>(find.text(_title));
      expect(title.didExceedMaxLines, isFalse);
    });
  }
}
