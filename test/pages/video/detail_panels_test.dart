import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/app_viewport.dart';
import 'package:pili_aurora/pages/video/widgets/detail_panels.dart';

Widget _panel(int index) => Center(
  key: ValueKey('panel-$index'),
  child: Text('内容 $index'),
);

Widget _page({
  required double width,
  double scale = 1,
  double textScale = 1,
  int count = 3,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: width / scale,
      height: 600 / scale,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 600)),
        child: AppViewport(
          uiScale: scale,
          textScale: textScale,
          insets: ViewportInsets(),
          child: DefaultTabController(
            length: count,
            child: Builder(
              builder: (context) => VideoDetailPanels(
                headerBuilder: (sideBySide) => TabBar(
                  key: ValueKey(sideBySide ? 'parallel' : 'tabbed'),
                  tabs: [for (var i = 0; i < count; i++) Tab(text: '$i')],
                ),
                panelBuilders: [
                  for (var i = 0; i < count; i++) (_) => _panel(i),
                ],
                tabbedBuilder: (children) => TabBarView(children: children),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('缩放、窗口和字体变化时保持详情可访问及选中标签', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(width: 1045, scale: 1.5));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tabbed')), findsOneWidget);
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();

    // 同一挂载依次经历并排、字体放大和窄窗，验证布局切换中的状态交接。
    for (final (width, textScale, parallel) in [
      (1200.0, 1.0, true),
      (1200.0, 1.5, false),
      (700.0, 1.0, false),
    ]) {
      await tester.pumpWidget(_page(width: width, textScale: textScale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(ValueKey(parallel ? 'parallel' : 'tabbed')),
        findsOneWidget,
      );
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index,
        1,
      );
      expect(
        find.byKey(const ValueKey('panel-1')).hitTestable(),
        findsOneWidget,
      );
      if (parallel) {
        for (var i = 0; i < 3; i++) {
          expect(
            find.byKey(ValueKey('panel-$i')).hitTestable(),
            findsOneWidget,
          );
        }
      }
    }
  });
}
