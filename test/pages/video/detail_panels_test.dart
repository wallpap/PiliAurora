import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/app_viewport.dart';
import 'package:pili_aurora/pages/video/widgets/detail_panels.dart';

Widget _panel(int index) => Column(
  key: ValueKey('panel-$index'),
  children: const [
    Row(children: [SizedBox(width: 180, height: 32), SizedBox(width: 140)]),
  ],
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
  testWidgets('scaled near-square window keeps each detail panel readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page(width: 1045, scale: 1.5));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tabbed')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-0')), findsOneWidget);
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide window retains parallel overview comments and playlist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_page(width: 1200));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('parallel')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('panel-$i')), findsOneWidget);
    }
  });

  testWidgets(
    'larger text requests tabbed panels rather than clipping controls',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_page(width: 1200, textScale: 1.5));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tabbed')), findsOneWidget);
    },
  );

  testWidgets('window resizing preserves the selected comment tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page(width: 700));
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_page(width: 1200));
    expect(find.byKey(const ValueKey('parallel')), findsOneWidget);
    await tester.pumpWidget(_page(width: 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tabbed')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
