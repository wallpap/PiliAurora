import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// 不联网、不访问账户；验证真实 WebView 页面与容器析构。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final loaded = Completer<InAppWebViewController>();
  final view = HeadlessInAppWebView(
    initialSize: const Size(320, 120),
    initialData: InAppWebViewInitialData(
      data: '<!doctype html><title>Lifecycle fixture</title><p id="test">ready</p>',
    ),
    onLoadStop: (controller, url) {
      if (!loaded.isCompleted) loaded.complete(controller);
    },
  );
  try {
    await view.run();
    final controller = await loaded.future.timeout(const Duration(seconds: 20));
    final text = await controller.evaluateJavascript(
      source: 'document.getElementById("test").textContent',
    );
    if (text != 'ready') throw StateError('Unexpected local WebView DOM');
    stdout.writeln('WEBVIEW_DOM_CONFIRMED');
    await view.dispose();
    stdout.writeln('WEBVIEW_FIXTURE_READY code=0');
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    await view.dispose();
    stdout.writeln('WEBVIEW_FIXTURE_READY code=1');
  }
}
