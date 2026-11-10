import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/models/common/webview_menu_type.dart';
import 'package:pili_aurora/pages/webview/view.dart';

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'fixture'),
      );

  final calls = <String>[];
  final handlers = <String, JavaScriptHandlerCallback>{};
  String? fail;
  String? url = 'https://example.test/page';
  bool back = false;
  Completer<WebUri?>? pendingUrl;
  Completer<bool>? pendingBack;
  Completer<void>? pendingClear;

  void record(String call) {
    calls.add(call);
    if (fail == call) throw PlatformException(code: 'private-token');
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) => handlers[handlerName] = callback;

  @override
  Future<void> reload() async => record('reload');

  @override
  Future<WebUri?> getUrl() async {
    record('getUrl');
    return pendingUrl == null
        ? (url == null ? null : WebUri(url!))
        : await pendingUrl!.future;
  }

  @override
  Future<bool> canGoBack() async {
    record('canGoBack');
    return await (pendingBack?.future ?? Future.value(back));
  }

  @override
  Future<void> goBack() async => record('goBack');

  @override
  Future<void> clearAllCache({bool includeDiskFiles = true}) async {
    record('clearAllCache');
    await pendingClear?.future;
  }

  @override
  Future<void> clearHistory() async => record('clearHistory');

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => record('evaluateJavascript');
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();

  final native = _Controller();
  late final controller = InAppWebViewController.fromPlatform(platform: native);
  bool created = false;

  @override
  Widget build(BuildContext context) {
    if (!created) {
      created = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        params.onWebViewCreated?.call(controller);
      });
    }
    return const SizedBox();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _Platform extends InAppWebViewPlatform {
  final cache = _Controller();
  late _View view;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => view = _View(params);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      cache;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _Platform();
  final copied = <String>[];
  setUpAll(() => InAppWebViewPlatform.instance = platform);
  setUp(() {
    copied.clear();
    platform.cache
      ..calls.clear()
      ..fail = null
      ..pendingClear = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    Get.reset();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/webview?url=https%3A%2F%2Fexample.test%2Fpage',
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        getPages: [
          GetPage(name: '/webview', page: () => const WebviewPage()),
          GetPage(
            name: '/other',
            page: () => const Scaffold(body: Text('其他页面')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, WebviewMenuItem item) async {
    tester
        .widget<PopupMenuButton<WebviewMenuItem>>(
          find.byType(PopupMenuButton<WebviewMenuItem>),
        )
        .onSelected!(item);
    await tester.pumpAndSettle();
  }

  Future<void> clearToasts(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await dismissed;
  }

  Future<void> finish(WidgetTester tester) async {
    await clearToasts(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('reload失败被消费并安全提示，失败后允许重试', (tester) async {
    await mount(tester);
    platform.view.native.fail = 'reload';
    await choose(tester, WebviewMenuItem.refresh);
    expect(find.text('网页操作失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
    await clearToasts(tester);
    platform.view.native.fail = null;
    await choose(tester, WebviewMenuItem.refresh);
    expect(platform.view.native.calls, ['reload', 'reload']);
    await finish(tester);
  });

  testWidgets('查询链接期间互斥其他菜单，成功复制确认后才提示', (tester) async {
    await mount(tester);
    final controller = platform.view.native..pendingUrl = Completer<WebUri?>();
    await choose(tester, WebviewMenuItem.copy);
    await choose(tester, WebviewMenuItem.goBack);
    expect(controller.calls, ['getUrl']);
    expect(copied, isEmpty);
    controller.pendingUrl!.complete(WebUri('https://example.test/confirmed'));
    await tester.pumpAndSettle();
    expect(copied, ['https://example.test/confirmed']);
    expect(find.text('已复制'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('空链接与getUrl失败不冒充复制成功，也不泄露原生错误', (tester) async {
    await mount(tester);
    platform.view.native.url = null;
    await choose(tester, WebviewMenuItem.copy);
    expect(find.text('暂无可用的网页链接'), findsOneWidget);
    await clearToasts(tester);
    platform.view.native.fail = 'getUrl';
    await choose(tester, WebviewMenuItem.copy);
    expect(find.text('链接复制失败，请重试'), findsOneWidget);
    expect(copied, isEmpty);
    expect(find.textContaining('private-token'), findsNothing);
    await finish(tester);
  });

  testWidgets('缓存和历史均完成才提示清理成功，任一步失败允许重试', (tester) async {
    await mount(tester);
    final controller = platform.view.native;
    platform.cache.fail = 'clearAllCache';
    await choose(tester, WebviewMenuItem.clearCache);
    expect(controller.calls, isEmpty);
    expect(find.text('缓存或浏览历史清理失败，请重试'), findsOneWidget);
    await clearToasts(tester);
    platform.cache.fail = null;
    controller.fail = 'clearHistory';
    await choose(tester, WebviewMenuItem.clearCache);
    expect(find.text('已清理'), findsNothing);
    expect(find.textContaining('private-token'), findsNothing);
    await clearToasts(tester);
    controller.fail = null;
    await choose(tester, WebviewMenuItem.clearCache);
    expect(find.text('已清理'), findsOneWidget);
    await finish(tester);
  });

  for (final action in [
    WebviewMenuItem.copy,
    WebviewMenuItem.openInBrowser,
    WebviewMenuItem.goBack,
  ]) {
    testWidgets('${action.name}查询离页后回包不能触发后续副作用', (tester) async {
      await mount(tester);
      final controller = platform.view.native
        ..pendingUrl = Completer<WebUri?>()
        ..pendingBack = Completer<bool>();
      await choose(tester, action);
      Get.toNamed('/other');
      await tester.pumpAndSettle();
      if (action == WebviewMenuItem.goBack) {
        controller.pendingBack!.complete(false);
      } else {
        controller.pendingUrl!.complete(WebUri('https://example.test/late'));
      }
      await tester.pumpAndSettle();
      expect(find.text('其他页面'), findsOneWidget);
      expect(copied, isEmpty);
      expect(controller.calls, [
        action == WebviewMenuItem.goBack ? 'canGoBack' : 'getUrl',
      ]);
      await finish(tester);
    });
  }

  testWidgets('缓存清理离页后不再清历史或显示成功', (tester) async {
    await mount(tester);
    platform.cache.pendingClear = Completer<void>();
    await choose(tester, WebviewMenuItem.clearCache);
    Get.toNamed('/other');
    await tester.pumpAndSettle();
    platform.cache.pendingClear!.complete();
    await tester.pumpAndSettle();
    expect(platform.view.native.calls, isEmpty);
    expect(find.text('已清理'), findsNothing);
    await finish(tester);
  });

  testWidgets('新加载不等待旧链接查询，旧结果不复制也不解除新操作的锁', (tester) async {
    await mount(tester);
    final view = platform.view;
    final oldUrl = Completer<WebUri?>();
    view.native.pendingUrl = oldUrl;
    await choose(tester, WebviewMenuItem.copy);
    view.params.onLoadStart!(
      view.controller,
      WebUri('https://example.test/new'),
    );
    final newUrl = Completer<WebUri?>();
    view.native.pendingUrl = newUrl;
    await choose(tester, WebviewMenuItem.copy);
    oldUrl.complete(WebUri('https://example.test/old'));
    await tester.pumpAndSettle();
    await choose(tester, WebviewMenuItem.goBack);
    expect(view.native.calls, ['getUrl', 'getUrl']);
    expect(copied, isEmpty);
    newUrl.complete(WebUri('https://example.test/new'));
    await tester.pumpAndSettle();
    expect(copied, ['https://example.test/new']);
    await finish(tester);
  });

  testWidgets('原生返回命令失败被消费并允许重试', (tester) async {
    await mount(tester);
    final controller = platform.view.native
      ..back = true
      ..fail = 'goBack';
    await choose(tester, WebviewMenuItem.goBack);
    expect(find.text('网页返回失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
    await clearToasts(tester);
    controller.fail = null;
    await choose(tester, WebviewMenuItem.goBack);
    expect(controller.calls, ['canGoBack', 'goBack', 'canGoBack', 'goBack']);
    await finish(tester);
  });

  testWidgets('旧WebView关闭事件不能关闭替换实例或新页面', (tester) async {
    await mount(tester);
    final view = platform.view;
    final replacement = InAppWebViewController.fromPlatform(
      platform: _Controller(),
    );
    view.params.onWebViewCreated!(replacement);
    view.params.onCloseWindow!(view.controller);
    await tester.pumpAndSettle();
    expect(find.byType(WebviewPage), findsOneWidget);
    Get.toNamed('/other');
    await tester.pumpAndSettle();
    view.params.onCloseWindow!(replacement);
    await tester.pumpAndSettle();
    expect(find.text('其他页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('网页脚本失败和无效oid由页面消费，不触发视频导航', (tester) async {
    await mount(tester);
    final view = platform.view;
    view.native.fail = 'evaluateJavascript';
    view.params.onLoadStop!(
      view.controller,
      WebUri('https://www.bilibili.com/h5/note-app'),
    );
    await tester.pumpAndSettle();
    view.native
      ..fail = null
      ..url = 'https://www.bilibili.com/h5/note-app?oid=invalid';
    await view.native.handlers['infoBarClicked']!([]);
    view.native.fail = 'getUrl';
    await view.native.handlers['infoBarClicked']!([]);
    expect(find.byType(WebviewPage), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
    await finish(tester);
  });
}
