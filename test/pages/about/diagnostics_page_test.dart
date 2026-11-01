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
  testWidgets('性能指标在窄屏下铺满双列并支持大字号', (tester) async {
    const width = 360.0;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diagnostics = Diagnostics(
      processReader: () => {'rssBytes': 123456},
    );
    addTearDown(diagnostics.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: DiagnosticsPage(diagnostics: diagnostics),
      ),
    );
    await tester.tap(find.text('性能记录'));
    await tester.pump();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump(const Duration(milliseconds: 300));
    Rect card(String title) => tester.getRect(
      find.ancestor(
        of: find.text(title),
        matching: find.byType(Card),
      ),
    );
    final first = card('进程工作集');
    final second = card('启动以来峰值');
    final third = card('私有提交');
    expect(second.top, first.top);
    expect(second.left - first.right, closeTo(8, 0.01));
    expect(second.width, first.width);
    expect(third.left, first.left);
    expect(third.top, greaterThan(first.bottom));
    expect(
      first.width + second.width + 8,
      closeTo(width - first.left * 2, 0.01),
    );
    expect(tester.takeException(), isNull);
    await diagnostics.configure(tracing: false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
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
