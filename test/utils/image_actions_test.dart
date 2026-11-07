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

  testWidgets('image failures close loading and preserve shared cache', (
    tester,
  ) async {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
    addTearDown(() => FilePickerPlatform.instance = previous);
    await tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
    );
    Future<void> checkLoadingClosed() async {
      await tester.pumpAndSettle();
      expect(SmartDialog.config.loading.isExist, isFalse);
      SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
    }

    expect(
      await ImageUtils.downloadImg([
        'https://example.test/ok',
        'https://example.test/fail',
      ]),
      isFalse,
    );
    await checkLoadingClosed();
    expect(manager.file.deleted, isFalse);
    expect(await ImageUtils.downloadImg(['https://example.test/ok']), isFalse);
    await checkLoadingClosed();
    await ImageUtils.onShareImg('https://example.test/fail');
    await checkLoadingClosed();
  });
}
