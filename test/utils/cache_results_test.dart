import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/setting/widgets/clear_cache_item.dart';
import 'package:pili_aurora/pages/setting/widgets/normal_item.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pili_aurora/utils/cache_manager.dart';

class _Cache extends Fake implements cache.DefaultCacheManager {
  @override
  late String cacheDir;
  Object? failure;
  @override
  int getTotalLength() => 0;
  @override
  Future<void> emptyCache() async {
    if (failure case final error?) throw error;
  }
}

class _Paths extends PathProviderPlatform {
  late String temporaryPath;
  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = _Cache();
  late Directory temporary;
  late Directory cacheDirectory;
  final paths = _Paths();
  late PathProviderPlatform originalPaths;
  setUpAll(() {
    CacheManager.manager = manager;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = paths;
  });
  tearDownAll(() => PathProviderPlatform.instance = originalPaths);
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('cache-results-');
    cacheDirectory = await Directory(path.join(temporary.path, 'images'))
        .create();
    manager
      ..cacheDir = cacheDirectory.path
      ..failure = null;
    paths.temporaryPath = temporary.path;
  });
  tearDown(() => temporary.delete(recursive: true));
  test('按实际图片文件统计，元数据为空不能把残留缓存显示为0', () async {
    await File(path.join(cacheDirectory.path, 'orphan'))
        .writeAsBytes([1, 2, 3]);
    final hive = await Directory(path.join(cacheDirectory.path, 'hive'))
        .create();
    await File(path.join(hive.path, 'metadata')).writeAsBytes([4, 5]);
    expect(await CacheManager.loadApplicationCache(), 3);
    await CacheManager.clearLibraryCache();
    expect(File(path.join(cacheDirectory.path, 'orphan')).existsSync(), false);
    expect(hive.existsSync(), true);
    expect(await CacheManager.loadApplicationCache(), 0);
  });
  test('读取与清理失败向消费方交付，不能变成0或成功', () async {
    final invalid = await File(path.join(temporary.path, 'not-directory'))
        .writeAsString('file');
    manager.cacheDir = invalid.path;
    paths.temporaryPath = invalid.path;
    await expectLater(
      CacheManager.loadApplicationCache(),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      CacheManager.clearLibraryCache(),
      throwsA(isA<FileSystemException>()),
    );
    manager.cacheDir = cacheDirectory.path;
    paths.temporaryPath = temporary.path;
    final error = StateError('synthetic clear failure');
    manager.failure = error;
    await expectLater(CacheManager.clearLibraryCache(), throwsA(same(error)));
  });
  testWidgets('缓存读取失败可重试，清理异常不显示成功且解除操作锁', (tester) async {
    final file = File(path.join(temporary.path, 'invalid'))
      ..writeAsStringSync('file');
    manager.cacheDir = file.path;
    paths.temporaryPath = file.path;
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: ClearCacheItem()),
      ),
    );
    Future<void> untilText(String text) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.textContaining(text).evaluate().isNotEmpty) return;
      }
      fail('未显示 $text');
    }

    await untilText('读取失败');
    manager.cacheDir = cacheDirectory.path;
    paths.temporaryPath = temporary.path;
    file.deleteSync();
    File(path.join(cacheDirectory.path, 'payload')).writeAsStringSync('file');
    await tester.tap(find.text('清除缓存'));
    await untilText('4.00B');
    manager.failure = StateError('private filesystem path');
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await untilText('部分缓存未能清除');
    expect(find.text('清除成功'), findsNothing);
    expect(find.textContaining('private filesystem path'), findsNothing);
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    for (
      var attempt = 0;
      attempt < 100 &&
          tester.widget<NormalItem>(find.byType(NormalItem)).onTap == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.widget<NormalItem>(find.byType(NormalItem)).onTap, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    Get.reset();
  });
}
