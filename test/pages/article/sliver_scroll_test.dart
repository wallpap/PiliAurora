import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/article/widgets/sliver_list.dart';
import 'package:pili_aurora/pages/article/widgets/sliver_to_box_adapter.dart';

void main() {
  for (final useList in [false, true]) {
    testWidgets('short article replies keep a full scroll extent: $useList', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              height: 400,
              child: CustomScrollView(
                controller: controller,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 200)),
                  if (useList)
                    ArticleSliverList.builder(
                      isArticle: true,
                      itemCount: 1,
                      itemBuilder: (_, _) => const SizedBox(height: 50),
                    )
                  else
                    const ArticleSliverToBoxAdapter(
                      child: SizedBox(height: 50),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(controller.position.maxScrollExtent, 200);
      controller.jumpTo(200);
      await tester.pump();
      expect(controller.offset, 200);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ordinary dynamic replies retain their natural extent', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomScrollView(
          controller: controller,
          slivers: [
            ArticleSliverList.builder(
              isArticle: false,
              itemCount: 1,
              itemBuilder: (_, _) => const SizedBox(height: 50),
            ),
          ],
        ),
      ),
    );
    expect(controller.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });
}
