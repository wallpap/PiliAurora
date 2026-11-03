import 'package:flutter/material.dart';
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
      expect(arguments?['progress'], expected);
    });
  }
}
