import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/dynamics/article_content_model.dart'
    show ArticleContentModel;
import 'package:pili_aurora/pages/article/widgets/opus_content.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    List<Map<String, dynamic>> paragraphs,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            OpusContent(
              opus: paragraphs.map(ArticleContentModel.fromJson).toList(),
              images: () => [],
              maxWidth: 800,
              opusId: 'fixture',
            ),
          ],
        ),
      ),
    ),
  );

  Map<String, dynamic> word(String text, [Map<String, dynamic>? fields]) => {
    'type': 'TEXT_NODE_TYPE_WORD',
    'word': {'words': text, ...?fields},
  };

  Text paragraph(WidgetTester tester, String text) => tester.widget<Text>(
    find.byWidgetPredicate(
      (widget) => widget is Text && widget.textSpan?.toPlainText() == text,
    ),
  );

  for (final type in [1, 4, 99, 8]) {
    testWidgets(
      'Opus paragraph type $type respects right and center alignment',
      (
        tester,
      ) async {
        await mount(tester, [
          for (final align in [0, 1, 2])
            {
              'para_type': type,
              'align': align,
              type == 8 ? 'heading' : 'text': {
                'nodes': [word('align $align')],
              },
            },
        ]);
        expect(paragraph(tester, 'align 0').textAlign, isNull);
        expect(paragraph(tester, 'align 1').textAlign, TextAlign.center);
        expect(paragraph(tester, 'align 2').textAlign, TextAlign.right);
      },
    );
  }

  testWidgets(
    'Opus font levels render on words and rich text without losing styles',
    (
      tester,
    ) async {
      await mount(tester, [
        {
          'para_type': 1,
          'text': {
            'nodes': [
              word('large', {'font_level': 'xxLarge'}),
              word('small', {'font_level': 'small'}),
              word('explicit', {
                'font_size': 19,
                'font_level': 'xxLarge',
                'style': {'bold': true},
              }),
              word('styled', {
                'style': {'font_level': 'xxLarge', 'italic': true},
              }),
              word('normal'),
              {
                'type': 'TEXT_NODE_TYPE_RICH',
                'rich': {
                  'type': 'RICH_TEXT_NODE_TYPE_TEXT',
                  'text': 'rich',
                  'style': {'font_level': 'xxLarge', 'strikethrough': true},
                },
              },
            ],
          },
        },
      ]);
      final spans =
          (paragraph(tester, 'largesmallexplicitstylednormalrich').textSpan!
                  as TextSpan)
              .children!
              .cast<TextSpan>()
              .toList();
      expect(spans.map((span) => span.style?.fontSize), [
        24,
        13,
        19,
        24,
        16,
        24,
      ]);
      expect(spans[2].style?.fontWeight, FontWeight.bold);
      expect(spans[3].style?.fontStyle, FontStyle.italic);
      expect(spans[5].style?.decoration, TextDecoration.lineThrough);
    },
  );
}
