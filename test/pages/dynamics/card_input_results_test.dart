import 'package:flutter/gestures.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/dynamics/article_content_model.dart'
    show ArticleContentModel;
import 'package:pili_aurora/pages/dynamics/widgets/rich_node_panel.dart';
import 'package:pili_aurora/pages/dynamics/widgets/additional_panel.dart';
import 'package:pili_aurora/pages/article/widgets/opus_content.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());
  tearDown(Get.reset);
  Future<void> mount(
    WidgetTester tester,
    Widget Function(BuildContext) child,
  ) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: ImageLoadingScope(
        enabled: false,
        child: Scaffold(body: Builder(builder: child)),
      ),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('富文本投票损坏ID点击后提示，不抛出解析错误', (tester) async {
    late TextSpan span;
    await mount(tester, (context) {
      final item = DynamicItemModel.fromJson({
        'modules': {
          'module_dynamic': {
            'desc': {
              'rich_text_nodes': [
                {
                  'type': 'RICH_TEXT_NODE_TYPE_VOTE',
                  'rid': 'invalid',
                  'text': '测试',
                },
              ],
            },
          },
        },
      });
      span = richNode(
        context,
        theme: Theme.of(context),
        floor: 1,
        isDetail: false,
        isSave: false,
        item: item,
      )!;
      return Text.rich(span);
    });
    final spans = <TextSpan>[];
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        spans.add(span);
        for (final child in span.children ?? <InlineSpan>[]) {
          visit(child);
        }
      }
    }

    visit(span);
    (spans.firstWhere((span) => span.recognizer != null).recognizer
            as TapGestureRecognizer)
        .onTap!();
    await tester.pump();
    expect(find.text('投票卡片信息无效'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  for (final id in <int?>[null, 0, -1]) {
    testWidgets('附加投票卡片拒绝无效voteId：$id', (tester) async {
      await mount(
        tester,
        (context) => addWidget(
          context,
          floor: 1,
          theme: Theme.of(context),
          idStr: 'invalid-dynamic',
          additional: DynamicAddModel(
            type: 'ADDITIONAL_TYPE_VOTE',
            vote: Vote(voteId: id, title: '投票', joinNum: 0),
          ),
        )!,
      );
      await tester.tap(find.text('投票'));
      await tester.pump();
      expect(find.text('投票卡片信息无效'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }
  testWidgets('专栏未识别卡片弹窗内的视频操作保留无效ID提示', (tester) async {
    await mount(
      tester,
      (_) => CustomScrollView(
        slivers: [
          OpusContent(
            opus: [
              ArticleContentModel.fromJson({
                'para_type': 6,
                'link_card': {
                  'card': {
                    'type': 'LINK_CARD_TYPE_ITEM_NULL',
                    'oid': 'invalid',
                    'item_null': {'text': '测试'},
                  },
                },
              }),
            ],
            images: () => [],
            maxWidth: 400,
            opusId: '1',
          ),
        ],
      ),
    );
    await tester.tap(find.text(' 测试: invalid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频'));
    await tester.pump();
    expect(find.text('视频卡片信息无效'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
