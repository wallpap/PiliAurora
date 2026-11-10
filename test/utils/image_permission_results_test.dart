import 'dart:async';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

class _Permissions extends PermissionHandlerPlatform {
  PermissionStatus status = PermissionStatus.granted;
  Object? requestError;
  Object? settingsError;
  bool opened = true;
  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    if (requestError != null) throw requestError!;
    return {for (final permission in permissions) permission: status};
  }

  @override
  Future<bool> openAppSettings() async {
    if (settingsError != null) throw settingsError!;
    return opened;
  }
}

class _Share {
  ShareResult result = ShareResult.unavailable;
  Object? error;
  Completer<void>? gate;
  int calls = 0;
  Future<String> handle(MethodCall call) async {
    calls++;
    await gate?.future;
    if (error != null) throw error!;
    return switch (result.status) {
      ShareResultStatus.dismissed => '',
      ShareResultStatus.unavailable => ShareResult.unavailable.raw,
      ShareResultStatus.success => 'synthetic-target',
    };
  }
}

class _Cache extends Fake implements cache.DefaultCacheManager {
  Object? error;
  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    if (error != null) throw error!;
    return File('synthetic-image.png');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final permissions = _Permissions();
  final share = _Share();
  final manager = _Cache();
  late PermissionHandlerPlatform oldPermissions;
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  setUpAll(() {
    GStorage.setting = MemoryBox();
    CacheManager.manager = manager;
    oldPermissions = PermissionHandlerPlatform.instance;
    PermissionHandlerPlatform.instance = permissions;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, share.handle);
  });
  setUp(() {
    permissions
      ..requestError = null
      ..settingsError = null
      ..opened = true
      ..status = PermissionStatus.granted;
    share
      ..error = null
      ..gate = null
      ..calls = 0;
    manager.error = null;
  });
  tearDownAll(() {
    PermissionHandlerPlatform.instance = oldPermissions;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allDialog);
    SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  test('权限查询保留受限和拒绝状态，插件失败保留原因与堆栈', () async {
    for (final status in PermissionStatus.values) {
      permissions.status = status;
      final result = await ImageUtils.requestPer();
      expect(result.data, status);
    }
    final cause = permissions.requestError = StateError(
      'synthetic private details',
    );
    final failed = await ImageUtils.requestPer();
    expect(failed, isA<Error>());
    expect((failed as Error).cause, same(cause));
    expect(failed.stackTrace, isNotNull);
    expect(failed.toString(), isNot(contains('synthetic private')));
  });

  testWidgets('保存仅接受已授权或有限授权，受限时提供取消与授权入口', (tester) async {
    await mount(tester);
    for (final status in PermissionStatus.values) {
      permissions.status = status;
      final allowed = await ImageUtils.checkPermissionDependOnSdkInt();
      expect(
        allowed,
        status == PermissionStatus.granted ||
            status == PermissionStatus.limited,
      );
      await tester.pumpAndSettle();
      if (!allowed) {
        expect(find.text('取消'), findsOneWidget);
        expect(find.text('去授权'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    }
    await finish(tester);
  });

  testWidgets('权限插件异常不抛出到保存调用方，提示不含异常正文', (tester) async {
    await mount(tester);
    permissions.requestError = StateError('secret-response');
    expect(await ImageUtils.checkPermissionDependOnSdkInt(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('无法获取存储权限，请稍后重试'), findsOneWidget);
    expect(find.textContaining('secret-response'), findsNothing);
    await finish(tester);
  });

  testWidgets('打开系统设置拒绝和异常均给可操作提示，成功返回 true', (tester) async {
    await mount(tester);
    expect(await ImageUtils.openPermissionSettings(), isTrue);
    permissions.opened = false;
    expect(await ImageUtils.openPermissionSettings(), isFalse);
    permissions.settingsError = StateError('secret-platform');
    expect(await ImageUtils.openPermissionSettings(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('无法打开系统设置，请手动前往应用权限设置'), findsWidgets);
    expect(find.textContaining('secret-platform'), findsNothing);
    await finish(tester);
  });

  testWidgets('系统分享保留取消和无法确认的状态，重复请求不重复打开分享', (tester) async {
    await mount(tester);
    for (final status in ShareResultStatus.values) {
      share.result = ShareResult('synthetic', status);
      final result = await ImageUtils.onShareImg(
        'https://example.test/image.png',
      );
      expect(result.data.status, status);
      await tester.pumpAndSettle();
      expect(SmartDialog.config.loading.isExist, isFalse);
    }
    final gate = share.gate = Completer<void>();
    final first = ImageUtils.onShareImg('https://example.test/image.png');
    await tester.pump();
    expect(
      await ImageUtils.onShareImg('https://example.test/image.png'),
      isA<Error>(),
    );
    // 其他操作在系统分享期间显示的 loading 不应被旧分享回执关闭。
    SmartDialog.showLoading(msg: '其他操作');
    await tester.pump();
    gate.complete();
    await tester.runAsync(() => first);
    await tester.pump();
    expect(SmartDialog.config.loading.isExist, isTrue);
    SmartDialog.dismiss(status: .loading);
    expect(share.calls, 4);
    await finish(tester);
  });

  testWidgets('分享下载和插件失败均释放提示并保留原始原因，不泄露正文', (tester) async {
    await mount(tester);
    final cause = StateError('private-url?token=secret');
    for (final failDownload in [true, false]) {
      manager.error = failDownload ? cause : null;
      share.error = failDownload
          ? null
          : PlatformException(
              code: 'synthetic',
              message: 'private-url?token=secret',
            );
      final result = await ImageUtils.onShareImg(
        'https://example.test/image.png',
      );
      expect(result, isA<Error>());
      final failure = result as Error;
      expect(
        failure.cause,
        failDownload ? same(cause) : isA<PlatformException>(),
      );
      expect(failure.stackTrace, isNotNull);
      await tester.pumpAndSettle();
      expect(SmartDialog.config.loading.isExist, isFalse);
      expect(find.text('图片分享失败，请重试'), findsOneWidget);
      expect(find.textContaining('private-url'), findsNothing);
      SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
    }
    await finish(tester);
  });
}
