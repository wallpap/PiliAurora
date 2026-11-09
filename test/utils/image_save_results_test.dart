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

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('pili-image-results-');
    tmpDirPath = directory.path;
    GStorage.setting = MemoryBox<dynamic>();
    ImageUtils.silentDownImg = false;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter = _Adapter();
  });
  setUp(() {
    previous = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
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
    CacheManager.manager = _Cache(source);
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
}

class _Picker extends FilePickerPlatform {
  Uri? target;
  String? directory;
  Uint8List? bytes;
  int directoryCalls = 0;

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
  final File file;
  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => file;
}

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    [1, 2, 3],
    200,
    headers: {
      'content-length': ['3'],
    },
  );
  @override
  void close({bool force = false}) {}
}
