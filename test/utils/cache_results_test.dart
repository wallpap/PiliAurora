import 'dart:async';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/setting/widgets/clear_cache_item.dart';
import 'package:pili_aurora/pages/setting/widgets/normal_item.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pili_aurora/utils/cache_manager.dart';

class _Cache extends Fake implements cache.DefaultCacheManager {
  @override
  late String cacheDir;
  Object? failure;
  Completer<void>? clearing;
  int clearCount = 0;
  @override
  int getTotalLength() => 0;
  @override
  Future<void> emptyCache() async {
    clearCount++;
    await clearing?.future;
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
      ..failure = null
      ..clearing = null
      ..clearCount = 0;
    paths.temporaryPath = temporary.path;
  });
  tearDown(() => temporary.delete(recursive: true));
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (ready()) return;
    }
    fail('缓存页面未完成预期状态转换');
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: ClearCacheItem()),
      ),
    );
    await until(
      tester,
      () => find.textContaining('0.00B').evaluate().isNotEmpty,
    );
  }

  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allToast);
    SmartDialog.dismiss(status: .allDialog);
    SmartDialog.dismiss(status: .loading);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    Get.reset();
  }

  testWidgets('取消清理保留缓存并允许再次确认', (tester) async {
    await mount(tester);
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.clearCount, 0);
    expect(tester.widget<NormalItem>(find.byType(NormalItem)).onTap, isNotNull);
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await finish(tester);
  });

  testWidgets('清理只关闭自己的提示，失败解除锁并允许重试', (tester) async {
    await mount(tester);
    final pending = manager.clearing = Completer<void>();
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(manager.clearCount, 1);
    expect(tester.widget<NormalItem>(find.byType(NormalItem)).onTap, isNull);
    SmartDialog.showLoading(msg: '其他任务');
    await tester.pump(const Duration(milliseconds: 500));
    manager.failure = StateError('private cache path');
    pending.complete();
    await until(
      tester,
      () => find.text('部分缓存未能清除，请稍后重试').evaluate().isNotEmpty,
    );
    expect(find.text('正在清除...'), findsNothing);
    expect(find.text('其他任务'), findsOneWidget);
    expect(find.textContaining('private cache path'), findsNothing);
    await until(
      tester,
      () => tester.widget<NormalItem>(find.byType(NormalItem)).onTap != null,
    );
    SmartDialog.dismiss(status: .loading);
    SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    expect(find.text('确认'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await finish(tester);
  });

  testWidgets('清理期间离页再返回不交付旧结果，保留新页面加载提示', (tester) async {
    await mount(tester);
    final pending = manager.clearing = Completer<void>();
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('正在清除...'), findsOneWidget);
    Get.key.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页面'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在清除...'), findsNothing);
    Get.key.currentState!.pop();
    await tester.pumpAndSettle();
    SmartDialog.showLoading(msg: '新页面任务');
    await tester.pump(const Duration(milliseconds: 500));
    manager.failure = StateError('late failure');
    pending.complete();
    await until(
      tester,
      () => tester.widget<NormalItem>(find.byType(NormalItem)).onTap != null,
    );
    expect(find.text('清除成功'), findsNothing);
    expect(find.text('部分缓存未能清除，请稍后重试'), findsNothing);
    expect(find.text('新页面任务'), findsOneWidget);
    await finish(tester);
  });
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
