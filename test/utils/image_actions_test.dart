import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/image_utils.dart';

class _Cache extends Fake implements cache.DefaultCacheManager {
  final file = _File();

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    if (url.endsWith('/fail')) throw const SocketException('download failed');
    return file;
  }
}

class _File extends Fake implements File {
  bool deleted = false;

  @override
  Future<File> delete({bool recursive = false}) async {
    deleted = true;
    return this;
  }
}

class _Picker extends FilePickerPlatform {
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => throw const FileSystemException('picker failed');
}

void main() {
  final manager = _Cache();
  setUpAll(() {
    CacheManager.manager = manager;
    ImageUtils.silentDownImg = false;
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
    );
  }

  Future<void> dismiss(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
  }

  testWidgets('partial download failure preserves shared cache files', (
    tester,
  ) async {
    await mount(tester);
    expect(
      await ImageUtils.downloadImg([
        'https://example.test/ok',
        'https://example.test/fail',
      ]),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(manager.file.deleted, isFalse);
    expect(SmartDialog.config.loading.isExist, isFalse);
    await dismiss(tester);
  });

  testWidgets('directory picker failure returns false and closes loading', (
    tester,
  ) async {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = previous);
    await mount(tester);
    expect(await ImageUtils.downloadImg(['https://example.test/ok']), isFalse);
    await tester.pumpAndSettle();
    expect(SmartDialog.config.loading.isExist, isFalse);
    await dismiss(tester);
  });

  testWidgets('share download failure closes loading', (tester) async {
    await mount(tester);
    await ImageUtils.onShareImg('https://example.test/fail');
    await tester.pumpAndSettle();
    expect(SmartDialog.config.loading.isExist, isFalse);
    await dismiss(tester);
  });
}
