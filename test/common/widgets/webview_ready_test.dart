import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/webview_ready.dart';

void main() {
  testWidgets('native content waits for preparation, then builds once', (
    tester,
  ) async {
    final ready = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WebViewReady(
          prepare: () => ready.future,
          builder: (_) {
            builds++;
            return const Text('native web content');
          },
        ),
      ),
    );
    expect(builds, 0);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.text('native web content'), findsOneWidget);
    expect(builds, 1);
  });

  testWidgets('leaving during initialization never creates native content', (
    tester,
  ) async {
    final ready = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WebViewReady(
          prepare: () => ready.future,
          builder: (_) {
            builds++;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    ready.complete();
    await tester.pumpAndSettle();
    expect(builds, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed preparation offers a retry before creating native content',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WebViewReady(
            prepare: () async {
              if (++attempts == 1) throw StateError('temporary native failure');
            },
            builder: (_) => const Text('native web content'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('native web content'), findsNothing);
      await tester.tap(find.text('网页初始化失败，点击重试'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('native web content'), findsOneWidget);
    },
  );
}
