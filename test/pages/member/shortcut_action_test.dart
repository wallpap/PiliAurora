import 'dart:async';
import 'dart:io';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/member/shortcut_action.dart';

void main() {
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(builder: FlutterSmartDialog.init(), home: const Scaffold()),
  );

  Future<void> finish(WidgetTester tester, Future<void> operation) async {
    await tester.pumpAndSettle();
    await operation;
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets(
    'icon failure closes its own loading, preserves other dialogs and permits retry',
    (tester) async {
      await mount(tester);
      var attempts = 0;
      var requests = 0;
      final action = MemberShortcutAction(
        loadIcon: (_) async {
          if (++attempts == 1) throw StateError('https://private?token=secret');
          return File('cached-icon.webp');
        },
        requestShortcut: (_, _, _, _) => requests++,
      );
      SmartDialog.show<void>(
        tag: 'other-operation',
        builder: (_) => const Text('其他操作'),
      );
      await tester.pumpAndSettle();
      var operation = action.run(
        mid: 1,
        username: '名称',
        avatar: 'https://example.test/icon',
        isCurrent: () => true,
      );
      await tester.pumpAndSettle();
      await operation;
      expect(find.text('正在创建快捷方式'), findsNothing);
      expect(find.text('其他操作'), findsOneWidget);
      expect(find.text('创建快捷方式失败，请重试'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(requests, 0);
      operation = action.run(
        mid: 1,
        username: '名称',
        avatar: 'https://example.test/icon',
        isCurrent: () => true,
      );
      await tester.pumpAndSettle();
      await operation;
      expect(requests, 1);
      SmartDialog.dismiss(tag: 'other-operation');
      await finish(tester, operation);
    },
  );

  testWidgets(
    'late icon result after page or profile replacement does not call native',
    (tester) async {
      await mount(tester);
      final pending = Completer<File>();
      var current = true;
      var requests = 0;
      var loads = 0;
      final action = MemberShortcutAction(
        loadIcon: (_) {
          loads++;
          return pending.future;
        },
        requestShortcut: (_, _, _, _) => requests++,
      );
      final operation = action.run(
        mid: 1,
        username: '旧名称',
        avatar: 'http://example.test/old',
        isCurrent: () => current,
      );
      await action.run(
        mid: 2,
        username: '新名称',
        avatar: 'https://example.test/new',
        isCurrent: () => true,
      );
      expect(loads, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      current = false;
      pending.complete(File('old.webp'));
      await finish(tester, operation);
      expect(requests, 0);
      expect(find.text('正在创建快捷方式'), findsNothing);
    },
  );

  testWidgets(
    'native failure is consumed and retry uses captured target values',
    (tester) async {
      await mount(tester);
      final pending = Completer<File>();
      var fail = true;
      final calls = <List<String>>[];
      final action = MemberShortcutAction(
        loadIcon: (_) => pending.future,
        requestShortcut: (id, uri, label, path) {
          calls.add([id, uri, label, path]);
          if (fail) throw StateError('native-private-response');
        },
      );
      var operation = action.run(
        mid: 7,
        username: '捕获名称',
        avatar: 'https://example.test/icon',
        isCurrent: () => true,
      );
      pending.complete(File('icon.webp'));
      await tester.pumpAndSettle();
      await operation;
      expect(find.text('创建快捷方式失败，请重试'), findsOneWidget);
      expect(find.textContaining('native-private-response'), findsNothing);
      fail = false;
      operation = action.run(
        mid: 7,
        username: '捕获名称',
        avatar: 'https://example.test/icon',
        isCurrent: () => true,
      );
      await finish(tester, operation);
      expect(calls, [
        ['7', 'bilibili://space/7', '捕获名称', 'icon.webp'],
        ['7', 'bilibili://space/7', '捕获名称', 'icon.webp'],
      ]);
    },
  );

  testWidgets('missing profile avoids loading and native request', (
    tester,
  ) async {
    await mount(tester);
    final action = MemberShortcutAction(
      loadIcon: (_) => throw StateError('must not load'),
      requestShortcut: (_, _, _, _) => fail('must not request'),
    );
    final operation = action.run(
      mid: 1,
      username: null,
      avatar: null,
      isCurrent: () => true,
    );
    await tester.pumpAndSettle();
    expect(find.text('请先加载空间资料后重试'), findsOneWidget);
    expect(find.text('正在创建快捷方式'), findsNothing);
    await finish(tester, operation);
  });
}
