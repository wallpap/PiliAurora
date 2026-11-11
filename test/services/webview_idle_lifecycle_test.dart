import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/webview_ready.dart';
import 'package:pili_aurora/services/webview_environment.dart';

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  int creations = 0, disposals = 0;
  Completer<void>? closing;
  Completer<void>? versionPending;
  @override
  Future<String?> getAvailableVersion({
    String? browserExecutableFolder,
  }) async {
    await versionPending?.future;
    return 'test';
  }

  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    creations++;
    return this;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await closing?.future;
  }
}

class _Platform extends InAppWebViewPlatform {
  final environment = _Environment();
  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      environment;
}

void main() {
  testWidgets(
    'last page and cookie operation release environment; reopening waits for disposal',
    (tester) async {
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      AppWebViewEnvironment.configure(userDataPath: 'isolated-idle-test');
      final environment = platform.environment;
      final cookieDone = Completer<void>();
      final cookie = AppWebViewEnvironment.using(() => cookieDone.future);
      await tester.pumpWidget(
        MaterialApp(home: WebViewReady(builder: (_) => const Text('web'))),
      );
      await tester.pumpAndSettle();
      expect(environment.creations, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      expect(
        environment.disposals,
        0,
        reason: 'pending cookie operation owns a lease',
      );
      cookieDone.complete();
      await tester.pump();
      await cookie;
      await tester.pump(const Duration(seconds: 4));
      // 快速重开取消回收，不反复支付初始化成本。
      await tester.pumpWidget(
        MaterialApp(home: WebViewReady(builder: (_) => const Text('reopened'))),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(environment.disposals, 0);
      environment.closing = Completer<void>();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      expect(environment.disposals, 1);
      expect(AppWebViewEnvironment.instance, isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: WebViewReady(builder: (_) => const Text('after close')),
        ),
      );
      await tester.pump();
      expect(
        environment.creations,
        1,
        reason: 'do not reuse native environment while it is closing',
      );
      environment.closing!.complete();
      await tester.pumpAndSettle();
      expect(environment.creations, 2);
      expect(find.text('after close'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      expect(environment.disposals, 2);
      // 初始化超过宽限期且页面已关闭时，迟到创建也必须回收。
      environment.versionPending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: WebViewReady(builder: (_) => const Text('late native content')),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      environment.versionPending!.complete();
      await tester.pumpAndSettle();
      expect(environment.creations, 3);
      expect(environment.disposals, 3);
      expect(AppWebViewEnvironment.instance, isNull);
      expect(find.text('late native content'), findsNothing);
    },
  );
}
