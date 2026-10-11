import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/app/desktop_playback_launch.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';

void main() {
  testWidgets('播放窗口启动路由传递参数并替换启动页', (tester) async {
    const request = DesktopPlaybackRequest.live(12345);
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/desktopPlayer',
        getPages: [
          GetPage(
            name: '/desktopPlayer',
            page: () => const DesktopPlaybackLaunch(request: request),
          ),
          GetPage(name: '/liveRoom', page: () => Text('room:${Get.arguments}')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('room:12345'), findsOneWidget);
    expect(Get.currentRoute, '/liveRoom');
    expect(Get.key.currentState!.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.reset();
  });
}
