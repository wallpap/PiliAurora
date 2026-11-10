import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/save_panel/view.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Picker extends FilePickerPlatform {
  int calls = 0;
  Uint8List? captured;
  Uri? result;
  Object? failure;
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
    captured = Uint8List.fromList(bytes);
    if (failure case final error?) throw error;
    return pending == null ? result : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FilePickerPlatform previousPicker;
  late _Picker picker;

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
  });
  setUp(() {
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() {
    FilePickerPlatform.instance = previousPicker;
    Get.reset();
  });

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (ready()) return;
    }
    fail('保存面板未完成预期状态转换');
  }

  Future<void> mount(WidgetTester tester) async {
    final item = DynamicItemModel.fromJson({
      'id_str': '123',
      'type': 'DYNAMIC_TYPE_WORD',
      'modules': {
        'module_author': {
          'name': '测试作者',
          'mid': 1,
          'face': '',
          'type': 'AUTHOR_TYPE_NORMAL',
        },
        'module_dynamic': {
          'desc': {
            'text': '保存内容',
            'rich_text_nodes': [
              {'type': 'RICH_TEXT_NODE_TYPE_TEXT', 'orig_text': '保存内容'},
            ],
          },
        },
      },
    });
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: TextButton(
            onPressed: () => SavePanel.toSavePanel(item: item),
            child: const Text('打开保存面板'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开保存面板'));
    await tester.pumpAndSettle();
    expect(find.text('保存内容', findRichText: true), findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allToast);
    SmartDialog.dismiss(status: .allDialog);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('实际截图取消和异常保留预览，成功后才关闭', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('保存'));
    await until(tester, () => picker.calls == 1);
    await tester.pumpAndSettle();
    expect(picker.captured!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(find.byType(SavePanel), findsOneWidget);
    picker.failure = StateError('private-save-response');
    await tester.tap(find.byTooltip('保存'));
    await until(tester, () => picker.calls == 2);
    await tester.pumpAndSettle();
    expect(find.byType(SavePanel), findsOneWidget);
    expect(find.text('图片保存或分享失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-save-response'), findsNothing);
    picker
      ..failure = null
      ..result = Uri.parse('content://synthetic/saved');
    await tester.tap(find.byTooltip('保存'));
    await until(tester, () => picker.calls == 3);
    await tester.pumpAndSettle();
    expect(find.byType(SavePanel), findsNothing);
    await finish(tester);
  });

  testWidgets('保存期间重复点击只提交一次，关闭预览不影响迟到保存', (tester) async {
    await mount(tester);
    picker.pending = Completer<Uri?>();
    await tester.tap(find.byTooltip('保存'));
    await until(tester, () => picker.calls == 1);
    await tester.tap(find.byTooltip('保存'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(picker.calls, 1);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    picker.pending!.complete(Uri.parse('content://synthetic/saved'));
    await tester.pumpAndSettle();
    expect(find.text('打开保存面板'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('保存期间离页再返回不因旧成功关闭预览', (tester) async {
    await mount(tester);
    picker.pending = Completer<Uri?>();
    await tester.tap(find.byTooltip('保存'));
    await until(tester, () => picker.calls == 1);
    Get.key.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页面'))),
    );
    await tester.pumpAndSettle();
    Get.key.currentState!.pop();
    await tester.pumpAndSettle();
    picker.pending!.complete(Uri.parse('content://synthetic/saved'));
    await tester.pumpAndSettle();
    expect(find.byType(SavePanel), findsOneWidget);
    await finish(tester);
  });
}
