import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/app_release.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/update.dart';

import '../support/memory_box.dart';

class _Settings extends MemoryBox<dynamic> {
  Completer<void>? pending;
  int saves = 0;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    saves++;
    await pending?.future;
    await super.put(key, value);
  }
}

void main() {
  final settings = _Settings();
  final release = AppRelease.latestStable([
    {'tag_name': 'v99.0.0', 'body': '更新说明'},
  ])!;
  setUpAll(() => GStorage.setting = settings);
  setUp(() async {
    settings
      ..pending = null
      ..saves = 0;
    await settings.clear();
  });
  tearDown(Get.reset);

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    Update.showUpdate(release, isAuto: true);
    await tester.pumpAndSettle();
  }

  Future<void> cleanup(WidgetTester tester) async {
    final closing = SmartDialog.dismiss(status: SmartStatus.allDialog);
    final toast = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await closing;
    await toast;
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('忽略版本等待保存回执，重复点击只保存一次，成功后关闭', (tester) async {
    settings.pending = Completer<void>();
    await mount(tester);
    await tester.tap(find.text('此版本不再提醒'));
    await tester.pump();
    await tester.tap(find.text('此版本不再提醒'));
    await tester.pump();
    expect(settings.saves, 1);
    expect(find.text('发现新版本 v99.0.0'), findsOneWidget);
    expect(settings.get(SettingBoxKey.updateIgnoredVersion), isNull);
    settings.pending!.complete();
    await tester.pumpAndSettle();
    expect(settings.get(SettingBoxKey.updateIgnoredVersion), release.tag);
    expect(find.text('发现新版本 v99.0.0'), findsNothing);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  testWidgets('忽略版本保存失败保留弹窗，提示安全文案并允许重试', (tester) async {
    settings.pending = Completer<void>();
    await mount(tester);
    await tester.tap(find.text('此版本不再提醒'));
    await tester.pump();
    settings.pending!.completeError(StateError('private-value'));
    await tester.pumpAndSettle();
    expect(find.text('设置未保存，请重试'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
    expect(find.text('发现新版本 v99.0.0'), findsOneWidget);
    expect(settings.get(SettingBoxKey.updateIgnoredVersion), isNull);
    settings.pending = null;
    await tester.tap(find.text('此版本不再提醒'));
    await tester.pumpAndSettle();
    expect(settings.saves, 2);
    expect(settings.get(SettingBoxKey.updateIgnoredVersion), release.tag);
    expect(find.text('发现新版本 v99.0.0'), findsNothing);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  for (final failed in [false, true]) {
    testWidgets('弹窗关闭后的迟到${failed ? '失败不提示' : '成功不关闭新弹窗'}', (tester) async {
      settings.pending = Completer<void>();
      await mount(tester);
      await tester.tap(find.text('此版本不再提醒'));
      await tester.pump();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      Update.showUpdate(release, isAuto: true);
      await tester.pumpAndSettle();
      if (failed) {
        settings.pending!.completeError(StateError('private-value'));
      } else {
        settings.pending!.complete();
      }
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 v99.0.0'), findsOneWidget);
      expect(find.text('设置未保存，请重试'), findsNothing);
      expect(tester.takeException(), isNull);
      await cleanup(tester);
    });
  }
}
