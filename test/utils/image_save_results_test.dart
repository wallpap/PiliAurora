import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  late Directory directory;
  late _Picker picker;
  late FilePickerPlatform previous;
  late _Adapter adapter;
  late _Cache manager;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('pili-image-results-');
    tmpDirPath = directory.path;
    GStorage.setting = MemoryBox<dynamic>();
    manager = _Cache(File('${directory.path}/unused.png'));
    CacheManager.manager = manager;
    ImageUtils.silentDownImg = false;
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    previous = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
    ImageUtils.silentDownImg = false;
    manager
      ..gate = null
      ..calls = 0;
  });
  tearDown(() => FilePickerPlatform.instance = previous);
  tearDownAll(() {
    Request.dio.close(force: true);
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
  );
  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await dismissal;
  }

  Future<void> settleLoading(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('动态图片取消保存返回 false 并释放加载提示', (tester) async {
    await mount(tester);
    final result = await tester.runAsync(
      () => ImageUtils.downloadLivePhoto(
        liveUrl: 'https://example.test/live.mp4',
      ),
    );
    expect(result, isFalse);
    expect(picker.bytes, [1, 2, 3]);
    await tester.pumpAndSettle();
    expect(SmartDialog.config.loading.isExist, isFalse);
    expect(directory.listSync(), isEmpty);
    await finish(tester);
  });

  testWidgets('文件保存提供真实字节并保留原文件，缺失与取消分别返回失败和 null', (tester) async {
    await mount(tester);
    final source = File('${directory.path}/source.png')
      ..writeAsBytesSync([4, 5, 6]);
    // 允许用户选择原路径；选择器负责写入，不应先截断源文件再复制。
    picker.target = source.uri;
    final saved = await tester.runAsync(
      () => ImageUtils.saveFileImg(
        filePath: source.path,
        fileName: 'source.png',
        needToast: true,
      ),
    );
    expect(saved?.isSuccess, isTrue);
    expect(source.readAsBytesSync(), [4, 5, 6]);
    expect(picker.bytes, [4, 5, 6]);

    picker.target = null;
    final cancelled = await tester.runAsync(
      () => ImageUtils.saveFileImg(
        filePath: source.path,
        fileName: 'source.png',
      ),
    );
    expect(cancelled, isNull);
    final missing = await ImageUtils.saveFileImg(
      filePath: '${directory.path}/missing.png',
      fileName: 'missing.png',
    );
    expect(missing?.isSuccess, isFalse);
    expect(missing?.errorMessage, '文件不存在');
    await finish(tester);
  });

  testWidgets('字节保存直接交给选择器，不要求返回本地文件 URI', (tester) async {
    await mount(tester);
    picker.target = Uri.parse('content://synthetic/saved');
    final saved = await ImageUtils.saveByteImg(
      bytes: Uint8List.fromList([7, 8, 9]),
      fileName: 'image',
    );
    expect(saved?.isSuccess, isTrue);
    expect(picker.bytes, [7, 8, 9]);
    await finish(tester);
  });

  testWidgets('批量保存复制缓存文件，空列表不报告成功或打开选择器', (tester) async {
    await mount(tester);
    final source = File('${directory.path}/cached.png')
      ..writeAsBytesSync([1, 3, 5]);
    final destination = Directory('${directory.path}/saved')..createSync();
    manager.file = source;
    picker.directory = destination.path;
    final result = await tester.runAsync(
      () => ImageUtils.downloadImg([
        'https://example.test/image.png',
      ]),
    );
    expect(result, isTrue);
    expect(source.existsSync(), isTrue);
    expect(File('${destination.path}/image.png').readAsBytesSync(), [1, 3, 5]);
    expect(await ImageUtils.downloadImg([]), isFalse);
    expect(picker.directoryCalls, 1);
    await finish(tester);
  });

  testWidgets('普通图片下载互斥并去重，偏好变化不会关闭其他操作的提示', (tester) async {
    await mount(tester);
    final source = File('${directory.path}/concurrent.png')
      ..writeAsBytesSync([1, 2]);
    final cacheGate = Completer<File>();
    manager
      ..file = source
      ..gate = cacheGate;
    final saving = ImageUtils.downloadImg([
      'https://example.test/concurrent.png',
      'https://example.test/concurrent.png',
    ]);
    await tester.pump();
    expect(
      await ImageUtils.downloadImg(['https://example.test/other.png']),
      isFalse,
    );
    expect(
      await ImageUtils.downloadLivePhoto(
        liveUrl: 'https://example.test/live.mp4',
      ),
      isFalse,
    );
    expect(manager.calls, 1);
    expect(adapter.calls, 0);
    SmartDialog.showLoading(msg: '其他操作');
    ImageUtils.silentDownImg = true;
    cacheGate.complete(source);
    expect(await saving, isFalse); // 取消目录选择。
    await settleLoading(tester);
    expect(SmartDialog.config.loading.isExist, isTrue);
    expect(find.text('正在下载原图'), findsNothing);
    expect(picker.directoryCalls, 1);
    expect(source.existsSync(), isTrue);
    SmartDialog.dismiss(status: .loading);
    await settleLoading(tester);
    await finish(tester);
  });

  testWidgets('动态图片成功、取消及下载失败仅清理独立临时目录，并允许重试', (tester) async {
    await mount(tester);
    final sentinel = File('${directory.path}/unrelated.mp4')
      ..writeAsBytesSync([9]);
    for (final status in [200, 503, 200]) {
      adapter.status = status;
      picker.target = status == 200 && picker.bytes == null
          ? Uri.parse('content://synthetic/saved')
          : null;
      final expected = status == 200 && picker.target != null;
      final saved = await tester.runAsync(
        () => ImageUtils.downloadLivePhoto(
          liveUrl: 'https://example.test/same.mp4',
        ),
      );
      expect(saved, expected);
      expect(sentinel.readAsBytesSync(), [9]);
      expect(
        directory.listSync().whereType<Directory>().where(
          (entry) => entry.path.contains('live-image-'),
        ),
        isEmpty,
      );
      await settleLoading(tester);
      await finish(tester);
      await mount(tester);
    }
    sentinel.deleteSync();
  });

  testWidgets('下载期间取消提示丢弃迟到结果，随后可重试', (tester) async {
    await mount(tester);
    final source = File('${directory.path}/cancelled.png')
      ..writeAsBytesSync([2, 4]);
    final gate = Completer<File>();
    manager
      ..file = source
      ..gate = gate;
    final saving = ImageUtils.downloadImg([
      'https://example.test/cancelled.png',
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    SmartDialog.dismiss(status: .allDialog);
    await settleLoading(tester);
    gate.complete(source);
    expect(await saving, isFalse);
    expect(picker.directoryCalls, 0);
    manager.gate = null;
    expect(
      await ImageUtils.downloadImg(['https://example.test/cancelled.png']),
      isFalse,
    );
    expect(picker.directoryCalls, 1);
    await settleLoading(tester);
    await finish(tester);
  });

  testWidgets('批量同名图片自动编号，已有文件和共享缓存原路径不被覆盖', (tester) async {
    await mount(tester);
    final source = File('${directory.path}/keep.png')
      ..writeAsBytesSync([1, 2, 3]);
    final destination = Directory('${directory.path}/names')..createSync();
    File('${destination.path}/same.png').writeAsBytesSync([9]);
    manager.file = source;
    picker.directory = destination.path;
    expect(
      await tester.runAsync(
        () => ImageUtils.downloadImg([
          'https://first.test/same.png',
          'https://second.test/same.png',
        ]),
      ),
      isTrue,
    );
    expect(File('${destination.path}/same.png').readAsBytesSync(), [9]);
    expect(File('${destination.path}/same (1).png').readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    expect(File('${destination.path}/same (2).png').readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    picker.directory = directory.path;
    expect(
      await tester.runAsync(
        () => ImageUtils.downloadImg(['https://example.test/keep.png']),
      ),
      isTrue,
    );
    expect(source.readAsBytesSync(), [1, 2, 3]);
    await settleLoading(tester);
    await finish(tester);
  });

  testWidgets('动态图片保存异常清理临时文件并保留其他操作提示', (tester) async {
    await mount(tester);
    picker.error = StateError('private-path');
    SmartDialog.showLoading(msg: '其他操作');
    expect(
      await tester.runAsync(
        () => ImageUtils.downloadLivePhoto(
          liveUrl: 'https://example.test/live.mp4',
        ),
      ),
      isFalse,
    );
    await settleLoading(tester);
    expect(SmartDialog.config.loading.isExist, isTrue);
    expect(find.textContaining('private-path'), findsNothing);
    expect(
      directory.listSync().whereType<Directory>().where(
        (entry) => entry.path.contains('live-image-'),
      ),
      isEmpty,
    );
    SmartDialog.dismiss(status: .loading);
    await settleLoading(tester);
    await finish(tester);
  });
}

class _Picker extends FilePickerPlatform {
  Uri? target;
  String? directory;
  Uint8List? bytes;
  int directoryCalls = 0;
  Object? error;

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
    this.bytes = Uint8List.fromList(bytes);
    if (error != null) throw error!;
    if (target?.scheme == 'file') File.fromUri(target!).writeAsBytesSync(bytes);
    return target;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    directoryCalls++;
    return directory;
  }
}

class _Cache extends Fake implements cache.DefaultCacheManager {
  _Cache(this.file);
  File file;
  Completer<File>? gate;
  int calls = 0;
  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    calls++;
    return gate?.future ?? file;
  }
}

class _Adapter implements HttpClientAdapter {
  int status = 200;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromBytes(
      [1, 2, 3],
      status,
      headers: {
        'content-length': ['3'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
