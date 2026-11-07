import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

void main() {
  setUpAll(() {
    GStorage.setting = MemoryBox({SettingBoxKey.hideTopBar: false});
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox<UserInfoData>();
  });

  setUp(() {
    Get.testMode = true;
    Get.put(AccountService());
  });

  tearDown(() {
    Get
      ..deleteAll(force: true)
      ..reset();
  });

  testWidgets('Get 删除首页控制器时注销诊断源', (tester) async {
    final controller = Get.put<HomeController>(HomeController());
    expect(Diagnostics.instance.readSources(prefix: 'homePage'), isNotEmpty);

    expect(Get.delete<HomeController>(), isTrue);

    expect(controller.isClosed, isTrue);
    expect(Diagnostics.instance.readSources(prefix: 'homePage'), isEmpty);
    expect(Get.delete<HomeController>(), isFalse);
    await tester.pump();
  });

  testWidgets('Get 删除时先释放首页 TabController 的活动 Ticker', (tester) async {
    final controller = _TickerHomeController();
    Get.put<HomeController>(controller);
    final tabs = controller.tabController;
    tabs.animateTo((tabs.index + 1) % tabs.length);
    expect(controller.ticker.isActive, isTrue);

    // 失败时也释放本用例的 Ticker，避免影响后续测试。
    addTearDown(() {
      if (tabs.animation != null) tabs.dispose();
    });
    expect(Get.delete<HomeController>(), isTrue);

    expect(controller.ticker.isActive, isFalse);
    expect(tabs.animation, isNull);
    expect(() => tabs.addListener(() {}), throwsFlutterError);
    expect(Diagnostics.instance.readSources(prefix: 'homePage'), isEmpty);
    await tester.pump();
  });
}

class _TickerHomeController extends HomeController {
  late Ticker ticker;

  @override
  Ticker createTicker(TickerCallback onTick) =>
      ticker = super.createTicker(onTick);
}
