import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/setting/pages/font_setting.dart';
import 'package:pili_aurora/utils/font_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

class _Settings extends MemoryBox<dynamic> {
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async {
    await gate?.future;
    if (fail) throw const FileSystemException('synthetic preference failure');
    await super.putAll(entries);
  }
}

class _Picker extends FilePickerPlatform {
  List<PlatformFile> files = [];
  Object? error;
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (error != null) throw error!;
    return files;
  }
}

final class _Picked extends PlatformFile {
  _Picked(this.bytes);
  final Uint8List bytes;
  @override
  String get name => 'preview.ttf';
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Uint8List bytes;
  final settings = _Settings();
  final picker = _Picker();
  late FilePickerPlatform previousPicker;
  const legacy = (fontFamily: '123/legacy', isCustom: true);
  const imported = (fontFamily: 'custom:123/new', isCustom: true);
  Future<LoadingState<void>> save(AppFont font, {Uint8List? data}) =>
      FontUtils.saveSettings(font: font, bytes: data, weight: 3, scale: 1);
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('font-results-');
    appSupportDirPath = directory.path;
    bytes = await File('assets/fonts/digital_id_num.ttf').readAsBytes();
    GStorage.setting = settings;
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
  });
  setUp(() async {
    settings
      ..fail = false
      ..gate = null;
    await settings.clear();
    for (final entry in directory.listSync()) {
      await entry.delete(recursive: true);
    }
    picker
      ..files = []
      ..error = null;
    await FontUtils.init();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    Get.reset();
  });
  tearDownAll(() async {
    FilePickerPlatform.instance = previousPicker;
    await directory.delete(recursive: true);
  });

  test('导入取消与失败有不同结果，错误保留原因和堆栈', () async {
    final cancel = await FontUtils.pickFonts();
    expect(cancel, isA<Success<Map<String, Uint8List>?>>());
    expect(cancel.data, isNull);
    final cause = picker.error = StateError('picker failed');
    final failed = await FontUtils.pickFonts();
    expect(failed, isA<Error>());
    expect((failed as Error).cause, same(cause));
    expect(failed.stackTrace, isNotNull);
    picker
      ..error = null
      ..files = [_Picked(bytes)];
    final selected = await FontUtils.pickFonts();
    expect(selected.data!.values.single, bytes);
    expect(selected.data!.keys.single, startsWith('custom:'));
  });

  test('空字体文件不被引擎回调当作成功导入', () async {
    picker.files = [_Picked(Uint8List(0))];
    final result = await FontUtils.pickFonts();
    expect(result, isA<Error>());
    expect((result as Error).cause, isA<FormatException>());
    expect(FontUtils.fontFamily, isNull);
    expect(settings.get(SettingBoxKey.appFont), isNull);
  });

  test('启动字体丢失返回错误并使用默认字体，不悄悄删除用户偏好', () async {
    await settings.put(SettingBoxKey.appFont, legacy.fontFamily);
    final result = await FontUtils.init();
    expect(result, isA<Error>());
    expect((result as Error).cause, isA<FileSystemException>());
    expect(FontUtils.fontFamily, isNull);
    expect(settings.get(SettingBoxKey.appFont), legacy.fontFamily);
  });

  test('新字体文件先落盘，偏好失败保留旧文件与确认值，重试兼容旧格式', () async {
    final oldFile = File('${directory.path}/customFont.otf');
    await oldFile.writeAsBytes(bytes);
    await settings.put(SettingBoxKey.appFont, legacy.fontFamily);
    expect((await FontUtils.init()).isSuccess, isTrue);
    settings.fail = true;
    expect(await save(imported, data: bytes), isA<Error>());
    expect(FontUtils.appFont, legacy);
    expect(settings.get(SettingBoxKey.appFont), legacy.fontFamily);
    expect(await oldFile.readAsBytes(), bytes);
    expect(directory.listSync(), hasLength(1));
    settings.fail = false;
    expect((await save(imported, data: bytes)).isSuccess, isTrue);
    expect(FontUtils.appFont, imported);
    expect(oldFile.existsSync(), isFalse);
    expect(directory.listSync(), hasLength(1));
    expect((await FontUtils.init()).isSuccess, isTrue);
    expect(FontUtils.appFont, imported);
  });

  test('文件写入失败不写偏好，不误报成功', () async {
    await Directory('${directory.path}/customFont-unused.otf').create();
    // 让支持目录暂时不可写为目录：写入发生在偏好之前。
    await directory.rename('${directory.path}-moved');
    final result = await save(imported, data: bytes);
    await Directory('${directory.path}-moved').rename(directory.path);
    expect(result, isA<Error>());
    expect(settings.get(SettingBoxKey.appFont), isNull);
    expect(FontUtils.fontFamily, isNull);
  });

  test('保存期间保持旧确认状态并拒绝重复提交，成功才清理旧自定义文件', () async {
    expect((await save(imported, data: bytes)).isSuccess, isTrue);
    final gate = settings.gate = Completer<void>();
    final pending = save((fontFamily: null, isCustom: false));
    await Future<void>.delayed(Duration.zero);
    expect(FontUtils.appFont, imported);
    expect(directory.listSync(), hasLength(1));
    expect(await save((fontFamily: 'Other', isCustom: false)), isA<Error>());
    gate.complete();
    expect((await pending).isSuccess, isTrue);
    expect(FontUtils.fontFamily, isNull);
    expect(directory.listSync(), isEmpty);
  });

  Future<void> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: TextButton(
            onPressed: () => Get.to(
              () => PrimaryScrollController(
                controller: scroll,
                child: const FontSettingPage(),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('字体设置保存失败保留草稿和页面，成功后才返回', (tester) async {
    await mount(tester);
    await tester.drag(find.byType(Slider).last, const Offset(50, 0));
    await tester.pumpAndSettle();
    settings.fail = true;
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('App字体设置'), findsOneWidget);
    expect(find.text('字体设置保存失败，请重试'), findsOneWidget);
    expect(settings.get(SettingBoxKey.defaultTextScale), isNull);
    settings.fail = false;
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('App字体设置'), findsNothing);
    expect(settings.get(SettingBoxKey.defaultTextScale), isNot(1));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('导入取消保留选择，导入失败可重试且不遗留加载遮罩', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('导入'));
    await tester.pumpAndSettle();
    expect(find.text('字体导入失败，请检查文件后重试'), findsNothing);
    expect(FontUtils.fontFamily, isNull);
    picker.error = const FileSystemException('picker failed');
    await tester.tap(find.byTooltip('导入'));
    await tester.pumpAndSettle();
    expect(find.text('字体导入失败，请检查文件后重试'), findsOneWidget);
    expect(find.text('App字体设置'), findsOneWidget);
    expect(SmartDialog.config.loading.isExist, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('保存期间禁用确认，迟到成功不会关闭新页面', (tester) async {
    await mount(tester);
    final gate = settings.gate = Completer<void>();
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存中'))
          .onPressed,
      isNull,
    );
    Get.back();
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    expect(settings.data.containsKey(SettingBoxKey.appFont), isTrue);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
