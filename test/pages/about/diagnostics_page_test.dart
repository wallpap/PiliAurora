import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/about/diagnostics_page.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  setUp(() {
    // 页面测试不等待真实引擎；JSON 通道需匹配生产 codec，避免遗留超时 Timer。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pili_aurora/graphics_memory', JSONMethodCodec()),
          (_) async => {'status': 'unsupported'},
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pili_aurora/graphics_memory', JSONMethodCodec()),
          null,
        );
  });
  testWidgets('复制日志时脱敏，页面记录保留原文', (tester) async {
    final diagnostics = Diagnostics();
    addTearDown(diagnostics.dispose);
    diagnostics.log(DiagnosticLogLevel.error, 'test', {
      'token': 'copy-secret',
      'state': 'ready',
    });
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsPage(diagnostics: diagnostics)),
    );
    await tester.tap(find.byTooltip('复制日志'));
    await tester.pump();
    expect(copied, isNot(contains('copy-secret')));
    expect(copied, contains('<redacted>'));
    expect(copied, contains('ready'));
    expect(
      diagnostics.recentLogs.single['message'],
      containsPair('token', 'copy-secret'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

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
