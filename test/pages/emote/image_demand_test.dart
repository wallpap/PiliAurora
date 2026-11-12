import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/pages/emote/controller.dart';
import 'package:pili_aurora/pages/emote/view.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Controller extends EmotePanelController {
  _Controller(this.package);
  final Package package;
  @override
  Future<LoadingState<List<Package>?>> customGetData() async =>
      Success([package]);
}

void main() {
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
  });
  setUp(() {
    (GStorage.localCache as MemoryBox).data.clear();
    Get.testMode = true;
  });
  tearDown(Get.reset);

  testWidgets(
    'ordinary image emotes mount only viewport and bounded neighbors',
    (tester) async {
      final emotes = List.generate(
        600,
        (index) => Emote(
          text: '[synthetic-$index]',
          url: 'https://example.test/emote-$index.webp',
        ),
      );
      final controller = Get.put<EmotePanelController>(
        _Controller(Package(type: 1, text: 'synthetic', emote: emotes)),
      );
      Emote? chosen;
      await tester.pumpWidget(
        ImageLoadingScope(
          enabled: false,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 320,
                  height: 300,
                  child: EmotePanel(onChoose: (emote, _, _) => chosen = emote),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final visible = find.byWidgetPredicate(
        (widget) =>
            widget is NetworkImgLayer &&
            widget.src?.startsWith('https://example.test/emote-') == true,
      );
      expect(visible.evaluate().length, greaterThan(0));
      expect(visible.evaluate().length, lessThan(100));
      final last = find.byWidgetPredicate(
        (widget) => widget is NetworkImgLayer && widget.src == emotes.last.url,
      );
      final packageGrid = find.byWidgetPredicate(
        (widget) =>
            widget is GridView &&
            widget.childrenDelegate.estimatedChildCount == emotes.length,
      );
      final scrollable = find
          .descendant(
            of: packageGrid,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(last, findsOneWidget);
      expect(visible.evaluate().length, lessThan(100));
      final selectable = find
          .ancestor(of: last, matching: find.byType(InkWell))
          .hitTestable();
      await tester.tap(selectable.first);
      expect(chosen?.url, emotes.last.url);
      await tester.pumpWidget(const SizedBox.shrink());
      Get.delete<EmotePanelController>(force: true);
      expect(controller.isClosed, isTrue);
    },
  );

  testWidgets('text emotes remain text and preserve chosen value', (
    tester,
  ) async {
    final emote = Emote(text: '(synthetic text)');
    Get.put<EmotePanelController>(
      _Controller(Package(type: 4, text: 'text', emote: [emote])),
    );
    Emote? chosen;
    double? chosenWidth = 1;
    await tester.pumpWidget(
      ImageLoadingScope(
        enabled: false,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 300,
              child: EmotePanel(
                onChoose: (value, width, _) {
                  chosen = value;
                  chosenWidth = width;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('(synthetic text)'));
    expect(chosen, same(emote));
    expect(chosenWidth, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.delete<EmotePanelController>(force: true);
  });
}
