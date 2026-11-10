import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';

void main() {
  late Completer<void> receipt;
  var fail = false;
  setUp(() {
    receipt = Completer<void>();
    fail = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (fail) {
              throw PlatformException(code: 'fixture', message: 'private text');
            }
            await receipt.future;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('剪贴板确认前不显示成功，完成后返回并提示', (tester) async {
    await mount(tester);
    var completed = false;
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = Utils.copyText('fixture').then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(find.text('已复制'), findsNothing);
    await tester.runAsync(() async {
      receipt.complete();
      await pending;
    });
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(find.text('已复制'), findsOneWidget);
    await finish(tester);
  });
  for (final share in [false, true]) {
    testWidgets('${share ? '桌面分享' : '复制'}消费平台失败且不泄露正文', (tester) async {
      await mount(tester);
      await tester.runAsync(() async {
        fail = true;
        await (share
            ? ShareUtils.shareText('private text')
            : Utils.copyText('private text'));
      });
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请重试'), findsOneWidget);
      expect(find.textContaining('private text'), findsNothing);
      expect(find.text('已复制'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    }, skip: share && !PlatformUtils.isDesktop);
  }
}
