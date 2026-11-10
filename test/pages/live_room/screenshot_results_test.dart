import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/item.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/user_info.dart';
import 'package:pili_aurora/pages/live_room/superchat/superchat_card.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Picker extends FilePickerPlatform {
  int calls = 0;
  Object? error;
  Completer<Uri?>? saving;
  VoidCallback? onSave;
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
    onSave?.call();
    if (error case final error?) throw error;
    if (saving case final saving?) return saving.future;
    return null;
  }
}

SuperChatItem item(int id) => SuperChatItem(
  id: id,
  uid: 1,
  price: 30,
  backgroundColor: '#EDF5FF',
  backgroundBottomColor: '#2A60B2',
  backgroundPriceColor: '#7497CD',
  messageFontColor: '#FFFFFF',
  startSime: 0,
  endTime: 1,
  message: '截图内容$id',
  token: '',
  ts: 0,
  roomid: 1,
  userInfo: UserInfo(
    face: '',
    faceFrame: null,
    uname: '截图用户',
    nameColor: '#666666',
  ),
);

void main() {
  late FilePickerPlatform previous;
  late _Picker picker;
  setUpAll(() {
    GStorage.setting = MemoryBox();
  });
  setUp(() {
    previous = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() {
    FilePickerPlatform.instance = previous;
  });

  Future<void> mount(
    WidgetTester tester,
    ValueNotifier<SuperChatItem> source,
  ) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      navigatorObservers: [routeObserver],
      home: Scaffold(
        body: ValueListenableBuilder<SuperChatItem>(
          valueListenable: source,
          builder: (_, value, _) =>
              SuperChatCard(item: value, persistentSC: true),
        ),
      ),
    ),
  );
  Future<VoidCallback> saveMenu(WidgetTester tester) async {
    await tester.tap(find.text('截图用户'));
    await tester.pumpAndSettle();
    final menu = tester.widget<AppPopupMenuItem>(
      find.ancestor(
        of: find.text('保存为图片'),
        matching: find.byType(AppPopupMenuItem),
      ),
    );
    // PopupMenuItem 正常点击先关闭菜单，再执行操作。
    final context = tester.element(find.text('保存为图片'));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    return menu.onTap!;
  }

  Future<void> drain(
    WidgetTester tester,
    FutureOr<void> Function() start,
  ) async {
    final previous = ui.Image.onDispose;
    try {
      await tester.runAsync(() async {
        final disposed = Completer<void>();
        ui.Image.onDispose = (image) {
          previous?.call(image);
          if (!disposed.isCompleted) disposed.complete();
        };
        await start();
        await disposed.future.timeout(const Duration(seconds: 3));
      });
    } finally {
      ui.Image.onDispose = previous;
    }
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('SC 保存失败安全提示，随后允许重试', (tester) async {
    final source = ValueNotifier(item(1));
    await mount(tester, source);
    final save = await saveMenu(tester);
    picker.error = StateError('private-token');
    await drain(tester, save);
    expect(picker.calls, 1);
    expect(find.textContaining('private-token'), findsNothing);
    expect(find.text('截图保存失败，请重试'), findsOneWidget);
    picker.error = null;
    await drain(tester, await saveMenu(tester));
    expect(picker.calls, 2);
    await finish(tester);
  });
  testWidgets('SC 条目替换后丢弃迟到截图且不打开保存器', (tester) async {
    final source = ValueNotifier(item(1));
    await mount(tester, source);
    final save = await saveMenu(tester);
    await drain(tester, () async {
      save();
      source.value = item(2);
      await tester.pump();
    });
    expect(picker.calls, 0);
    expect(find.text('截图保存失败，请重试'), findsNothing);
    await finish(tester);
  });

  for (final duringSave in [false, true]) {
    testWidgets('SC ${duringSave ? '保存' : '截图'}期间离页再返回后丢弃迟到结果', (tester) async {
      final source = ValueNotifier(item(1));
      await mount(tester, source);
      final save = await saveMenu(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await drain(tester, () async {
        final entered = Completer<void>();
        picker.onSave = entered.complete;
        if (duringSave) picker.saving = Completer<Uri?>();
        save();
        if (duringSave) {
          await entered.future.timeout(const Duration(seconds: 3));
          expect(picker.calls, 1);
          save(); // 原生保存未结束时，重复点击继续合并。
        }
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('新页面'))),
        );
        await tester.pumpAndSettle();
        expect(find.text('新页面'), findsOneWidget);
        navigator.pop();
        await tester.pumpAndSettle();
        picker.saving?.complete(null);
      });
      expect(picker.calls, duringSave ? 1 : 0);
      expect(find.text('取消保存'), findsNothing);
      expect(find.text('已保存'), findsNothing);
      expect(find.text('截图保存失败，请重试'), findsNothing);
      await finish(tester);
    });
  }
}
