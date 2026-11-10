import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/utils/app_scheme.dart';

void main() {
  tearDown(Get.reset);

  for (final (query, expected) in <(String, int?)>[
    ('dm_progress=123000', 120000),
    ('dm_progress=2000', 0),
    ('dm_progress=-1', 0),
    ('start_progress=12000&dm_progress=30000', 12000),
    ('t=2.5', 2500),
    ('dm_progress=invalid&t=2', null),
  ]) {
    testWidgets('视频链接进度 $query', (tester) async {
      Map? arguments;
      await tester.pumpWidget(
        GetMaterialApp(
          home: const Scaffold(),
          getPages: [
            GetPage(
              name: '/videoV',
              page: () {
                arguments = Get.arguments as Map;
                return const Scaffold();
              },
            ),
          ],
        ),
      );
      final handled = await PiliScheme.routePush(
        Uri.parse('bilibili://video/12345678?cid=42&$query'),
      );
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(arguments, isNotNull);
      expect(arguments!['cid'], 42);
      expect(arguments!['progress'], expected);
    });
  }
  for (final direct in [false, true]) {
    for (final url in [
      'bilibili://video/12345678?cid=invalid&secret=private-value',
      'bilibili://comment/detail/17?token=private-value',
      'https://space.bilibili.com/1/lists?sid=invalid&token=private-value',
      'bilibili://video/12345678?cid=42&t=NaN&token=private-value',
    ]) {
      testWidgets('畸形链接${direct ? '直接' : '字符串'}入口返回失败且不泄露查询内容 $url', (
        tester,
      ) async {
        await tester.pumpWidget(
          GetMaterialApp(
            builder: FlutterSmartDialog.init(),
            home: const Scaffold(),
          ),
        );
        final handled = await (direct
            ? PiliScheme.routePush(Uri.parse(url))
            : PiliScheme.routePushFromUrl(url));
        await tester.pumpAndSettle();
        expect(handled, isFalse);
        expect(find.text('链接无效或暂时无法打开'), findsOneWidget);
        expect(find.textContaining('private-value'), findsNothing);
        expect(tester.takeException(), isNull);
        final dismiss = SmartDialog.dismiss(status: .allToast);
        await tester.pumpAndSettle();
        await dismiss;
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('探测链接静默失败，未知链接提示不包含URL', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    expect(
      await PiliScheme.routePushFromUrl(
        'bilibili://video/1?cid=bad',
        selfHandle: true,
      ),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(find.text('链接无效或暂时无法打开'), findsNothing);
    expect(
      await PiliScheme.routePushFromUrl(
        'bilibili://unsupported?token=private-value',
      ),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(find.text('暂不支持此链接'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
    final dismiss = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismiss;
    await tester.pumpWidget(const SizedBox());
  });
}
