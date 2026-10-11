import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/about/diagnostics_page.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  testWidgets('unified logs filter channels and expand report details', (
    tester,
  ) async {
    final diagnostics = Diagnostics();
    addTearDown(diagnostics.dispose);
    diagnostics
      ..log(
        DiagnosticLogLevel.error,
        'exception',
        'app failure',
        stack: StackTrace.fromString('fixture stack'),
      )
      ..playerLog(
        DiagnosticLogLevel.info,
        'player',
        'playback started',
      );
    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsPage(diagnostics: diagnostics)),
    );
    expect(find.text('app failure'), findsOneWidget);
    expect(find.text('playback started'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, '错误'));
    await tester.pump();
    expect(find.text('playback started'), findsNothing);
    await tester.tap(find.byTooltip('展开'));
    await tester.pump();
    expect(find.textContaining('fixture stack'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '播放'));
    await tester.pump();
    expect(find.text('app failure'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'diagnostics page can enable sampling, stop it and change levels',
    (tester) async {
      final pageDiagnostics = Diagnostics(
        processReader: () => {'rssBytes': 123456},
      );
      addTearDown(pageDiagnostics.dispose);
      await tester.pumpWidget(
        MaterialApp(home: DiagnosticsPage(diagnostics: pageDiagnostics)),
      );
      await tester.tap(find.text('性能记录'));
      await tester.pump();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pageDiagnostics.tracing, isTrue);
      expect(find.text('进程工作集'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pageDiagnostics.tracing, isFalse);
      await tester.tap(find.text('日志等级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调试'));
      await tester.pumpAndSettle();
      expect(pageDiagnostics.level, DiagnosticLogLevel.debug);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
