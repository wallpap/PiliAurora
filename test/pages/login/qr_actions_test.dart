import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/login/controller.dart';
import 'package:pili_aurora/pages/login/view.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Controller extends LoginPageController {
  int refreshCount = 0;
  @override
  void onInit() {
    super.onInit();
    tabController.index = 2;
  }

  @override
  Future<void> refreshQRCode() async {
    codeInfo.value = Success((
      authCode: 'renewed-${++refreshCount}',
      url: 'https://qr.test/new',
    ));
    qrCodeLeftTime.value = 180;
  }
}

class _Picker extends FilePickerPlatform {
  int calls = 0;
  Uint8List? bytes;
  Uri? result;
  Object? error;
  Completer<Uri?>? pending;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    this.bytes = Uint8List.fromList(bytes);
    if (error case final error?) throw error;
    return pending == null ? result : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');
  late _Controller controller;
  late _Picker picker;
  late FilePickerPlatform previousPicker;
  final launches = <String>[];
  Completer<bool>? opening;
  Object? launchError;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
  });
  setUp(() {
    controller = _Controller();
    controller.codeInfo.value = const Success((
      authCode: 'first',
      url: 'https://qr.test/first',
    ));
    Get.put<LoginPageController>(controller);
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
    opening = null;
    launchError = null;
    launches.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, (call) async {
          if (call.method == 'launch') {
            launches.add((call.arguments as Map)['url'] as String);
            if (launchError case final error?) throw error;
            return opening == null ? true : opening!.future;
          }
          return false;
        });
  });
  tearDown(() {
    FilePickerPlatform.instance = previousPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcher, null);
    Get.reset();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        home: const LoginPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (ready()) return;
    }
    fail('二维码操作未到达预期状态');
  }

  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allToast);
    SmartDialog.dismiss(status: .allDialog);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('加载、错误、过期二维码的保存和外部打开都明确拒绝', (tester) async {
    await mount(tester);
    for (final state in <LoadingState<({String authCode, String url})>>[
      LoadingState.loading(),
      const Error('申请失败'),
    ]) {
      controller.codeInfo.value = state;
      await tester.pump();
      await tester.tap(find.text('其他应用打开'));
      await tester.tap(find.text('保存至相册'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    await controller.refreshQRCode();
    controller.qrCodeLeftTime.value = 0;
    await tester.pump();
    await tester.tap(find.text('其他应用打开'));
    await tester.tap(find.text('保存至相册'));
    await tester.pump();
    expect(launches, isEmpty);
    expect(picker.calls, 0);
    expect(find.text('请先刷新二维码'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('实际二维码截图保存取消、失败及重试均保留页面', (tester) async {
    await mount(tester);
    await tester.tap(find.text('保存至相册'));
    await until(tester, () => picker.calls == 1);
    await tester.pumpAndSettle();
    expect(picker.bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(find.text('取消保存'), findsOneWidget);
    SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    picker.error = StateError('private-save-response');
    await tester.tap(find.text('保存至相册'));
    await until(tester, () => picker.calls == 2);
    await tester.pumpAndSettle();
    expect(find.text('二维码截图保存失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-save-response'), findsNothing);
    SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    picker
      ..error = null
      ..result = Uri.parse('content://test/saved');
    await tester.tap(find.text('保存至相册'));
    await until(tester, () => picker.calls == 3);
    await tester.pumpAndSettle();
    expect(find.text(' 已保存 '), findsOneWidget);
    expect(find.byType(LoginPage), findsOneWidget);
    await finish(tester);
  });

  for (final change in ['刷新', '过期', '切换标签', '离页返回']) {
    testWidgets('保存期间$change后丢弃旧保存提示，重复点击不并发', (tester) async {
      await mount(tester);
      picker.pending = Completer<Uri?>();
      await tester.tap(find.text('保存至相册'));
      await until(tester, () => picker.calls == 1);
      await tester.tap(find.text('保存至相册'));
      expect(picker.calls, 1);
      switch (change) {
        case '刷新':
          await controller.refreshQRCode();
        case '过期':
          controller.qrCodeLeftTime.value = 0;
        case '切换标签':
          controller.tabController.index = 0;
          await tester.pumpAndSettle();
          controller.tabController.index = 2;
          await tester.pumpAndSettle();
        case '离页返回':
          Get.key.currentState!.push<void>(
            MaterialPageRoute(builder: (_) => const Scaffold()),
          );
          await tester.pumpAndSettle();
          Get.key.currentState!.pop();
          await tester.pumpAndSettle();
      }
      picker.pending!.complete(Uri.parse('content://test/late'));
      await tester.pumpAndSettle();
      expect(find.text(' 已保存 '), findsNothing);
      expect(find.text('正在生成截图'), findsNothing);
      await finish(tester);
    });
  }

  testWidgets('外部打开固定二维码，消费失败并允许重试', (tester) async {
    await mount(tester);
    launchError = PlatformException(code: 'synthetic', message: 'private-url');
    await tester.tap(find.text('其他应用打开'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开二维码，请重试'), findsOneWidget);
    expect(find.textContaining('private-url'), findsNothing);
    launchError = null;
    await controller.refreshQRCode();
    await tester.pump();
    await tester.tap(find.text('其他应用打开'));
    await tester.pumpAndSettle();
    expect(
      Uri.parse(launches.last).queryParameters['url'],
      'https://qr.test/new',
    );
    await finish(tester);
  });

  testWidgets('外部打开迟到失败不提示到新标签', (tester) async {
    await mount(tester);
    opening = Completer<bool>();
    await tester.tap(find.text('其他应用打开'));
    await tester.pump();
    controller.tabController.index = 0;
    await tester.pumpAndSettle();
    controller.tabController.index = 2;
    await tester.pumpAndSettle();
    opening!.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('无法打开二维码，请重试'), findsNothing);
    await finish(tester);
  });
}
