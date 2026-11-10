import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/models/content_settings.dart';
import 'package:pili_aurora/pages/setting/models/video_settings.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

class _Settings extends MemoryBox {
  bool fail = false;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (fail) throw StateError('private-storage');
    await super.put(key, value);
  }
}

void main() {
  final settings = _Settings();
  setUpAll(() {
    GStorage.setting = settings;
    GStorage.video = MemoryBox();
  });
  setUp(() {
    settings.fail = false;
    settings.data.clear();
  });
  tearDown(Get.reset);

  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: Scaffold(body: child),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
  }

  for (final (title, key, value, content) in [
    ('评论折叠行数', SettingBoxKey.replyLengthLimit, '8', true),
    ('音频时钟平滑', SettingBoxKey.autosync, '18', false),
    ('缓冲大小', SettingBoxKey.bufferSize, '12.5', false),
    ('直播 CDN 设置', SettingBoxKey.liveCdnUrl, 'cdn.example', false),
  ]) {
    testWidgets('$title保存失败保留草稿，重试后确认保存', (tester) async {
      final items = content ? contentSettings : videoSettings;
      final item = items
          .expand((item) => item.searchableItems)
          .firstWhere(
            (item) => item.effectiveTitle == title,
          );
      await mount(tester, item.widget);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), value);
      settings.fail = true;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(find.textContaining('private-storage'), findsNothing);
      expect(find.text(value), findsOneWidget);
      expect(settings.data.containsKey(key), false);
      settings.fail = false;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(settings.data.containsKey(key), true);
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester);
    });
  }

  testWidgets('自定义音量均衡保存失败保留参数，重试后落盘', (tester) async {
    await mount(
      tester,
      const NormalModel(title: '音量均衡', onTap: audioNormalization).widget,
    );
    await tester.tap(find.text('音量均衡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义参数'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'dynaudnorm=g=5');
    settings.fail = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.text('dynaudnorm=g=5'), findsOneWidget);
    settings.fail = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.data[SettingBoxKey.audioNormalization], 'dynaudnorm=g=5');
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('普通设置离页后消费迟到失败且不提示', (tester) async {
    final pending = Completer<void>();
    final visible = ValueNotifier(true);
    await mount(
      tester,
      ValueListenableBuilder(
        valueListenable: visible,
        builder: (_, show, _) => show
            ? NormalModel(
                title: '异步设置',
                onTap: (_, _) => pending.future,
              ).widget
            : const SizedBox(),
      ),
    );
    await tester.tap(find.text('异步设置'));
    await tester.pump();
    visible.value = false;
    await tester.pump();
    pending.completeError(StateError('private-save'));
    await tester.pumpAndSettle();
    expect(find.text('设置保存失败，请重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
    visible.dispose();
  });

  testWidgets('普通设置消费异步失败并阻止重复操作', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await mount(
      tester,
      NormalModel(
        title: '异步设置',
        onTap: (_, _) async {
          calls++;
          await pending.future;
          throw StateError('private-save');
        },
      ).widget,
    );
    await tester.tap(find.text('异步设置'));
    await tester.pump();
    await tester.tap(find.text('异步设置'));
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-save'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
