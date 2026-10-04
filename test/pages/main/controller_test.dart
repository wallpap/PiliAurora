import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-main-controller-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
  });

  setUp(() async {
    Get.testMode = true;
    await GStorage.setting.clear();
    await GStorage.setting.putAll({
      SettingBoxKey.autoUpdate: false,
      SettingBoxKey.hideBottomBar: false,
    });
    Get.put(AccountService()).isLogin.value = true;
  });

  tearDown(() {
    Get
      ..delete<MainController>(force: true)
      ..delete<AccountService>(force: true)
      ..reset();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final mainTabBarView in [false, true]) {
    testWidgets('initial badge requests run after the first frame, '
        'with mainTabBarView=$mainTabBarView', (tester) async {
      await tester.runAsync(
        () => GStorage.setting.put(
          SettingBoxKey.mainTabBarView,
          mainTabBarView,
        ),
      );
      late _CountingMainController controller;
      var requestsDuringBuild = -1;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (_) {
              controller = _CountingMainController();
              Get.put<MainController>(controller);
              requestsDuringBuild =
                  controller.dynamicCalls + controller.messageCalls;
              expect(controller.navigationBars, NavigationBarType.values);
              expect(
                controller.selectedIndex.value,
                NavigationBarType.home.index,
              );
              expect(controller.hasDyn, isTrue);
              expect(controller.hasHome, isTrue);
              expect(controller.lastCheckUnreadAt, greaterThan(0));
              return const Text('首屏');
            },
          ),
        ),
      );

      expect(find.text('首屏'), findsOneWidget);
      expect(requestsDuringBuild, 0);
      expect(controller.dynamicCalls, 1);
      expect(controller.messageCalls, 1);
      expect(
        controller.phases,
        everyElement(SchedulerPhase.postFrameCallbacks),
      );
      expect(
        controller.controller,
        mainTabBarView ? isA<TabController>() : isA<PageController>(),
      );

      // 既有节流时间戳仍在初始化时设置，页面恢复不会重复触发启动请求。
      controller
        ..checkUnreadDynamic()
        ..checkUnread();
      await tester.pump();
      await tester.pump();
      expect(controller.dynamicCalls, 1);
      expect(controller.messageCalls, 1);
    });
  }

  testWidgets('closing before the first frame cancels deferred requests', (
    tester,
  ) async {
    final controller = _CountingMainController();
    Get.put<MainController>(controller);
    expect(controller.dynamicCalls, 0);
    expect(controller.messageCalls, 0);

    tester.binding.scheduleFrame();
    Get.delete<MainController>(force: true);
    expect(controller.isClosed, isTrue);
    await tester.pump();

    expect(controller.dynamicCalls, 0);
    expect(controller.messageCalls, 0);
  });

  for (final scenario in [
    (
      'dynamic tab',
      NavigationBarType.values,
      NavigationBarType.dynamics,
      DynamicBadgeMode.number,
      DynamicBadgeMode.number,
      0,
      1,
    ),
    (
      'hidden badges',
      NavigationBarType.values,
      NavigationBarType.home,
      DynamicBadgeMode.hidden,
      DynamicBadgeMode.hidden,
      0,
      0,
    ),
    (
      'no dynamic tab',
      [NavigationBarType.home, NavigationBarType.mine],
      NavigationBarType.home,
      DynamicBadgeMode.number,
      DynamicBadgeMode.number,
      0,
      1,
    ),
    (
      'no home tab',
      [NavigationBarType.dynamics, NavigationBarType.mine],
      NavigationBarType.mine,
      DynamicBadgeMode.number,
      DynamicBadgeMode.number,
      1,
      0,
    ),
    (
      'only mine tab',
      [NavigationBarType.mine],
      NavigationBarType.home,
      DynamicBadgeMode.number,
      DynamicBadgeMode.number,
      0,
      0,
    ),
  ]) {
    final (
      name,
      tabs,
      defaultTab,
      dynamicBadge,
      messageBadge,
      expectedDynamic,
      expectedMessages,
    ) = scenario;
    testWidgets('preserves startup request conditions: $name', (tester) async {
      await tester.runAsync(
        () => GStorage.setting.putAll({
          SettingBoxKey.navBarSort: tabs.map((tab) => tab.index).toList(),
          SettingBoxKey.defaultHomePage: defaultTab.index,
          SettingBoxKey.dynamicBadgeMode: dynamicBadge.index,
          SettingBoxKey.msgBadgeMode: messageBadge.index,
        }),
      );
      late _CountingMainController controller;
      var dynamicCallsDuringBuild = -1;
      var messageCallsDuringBuild = -1;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (_) {
              controller = _CountingMainController();
              Get.put<MainController>(controller);
              dynamicCallsDuringBuild = controller.dynamicCalls;
              messageCallsDuringBuild = controller.messageCalls;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(dynamicCallsDuringBuild, 0);
      expect(messageCallsDuringBuild, 0);
      expect(controller.dynamicCalls, expectedDynamic);
      expect(controller.messageCalls, expectedMessages);
      expect(controller.navigationBars, tabs);
      expect(
        controller.navigationBars[controller.selectedIndex.value],
        tabs.contains(defaultTab) ? defaultTab : tabs.first,
      );
      expect(
        controller.lastCheckUnreadAt,
        expectedMessages == 0 ? 0 : greaterThan(0),
      );

      await tester.pump();
      expect(controller.dynamicCalls, expectedDynamic);
      expect(controller.messageCalls, expectedMessages);
    });
  }

  testWidgets('disabling periodic dynamic checks keeps the initial request', (
    tester,
  ) async {
    await tester.runAsync(
      () => GStorage.setting.put(
        SettingBoxKey.checkDynamic,
        false,
      ),
    );
    late _CountingMainController controller;
    var dynamicCallsDuringBuild = -1;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (_) {
            controller = _CountingMainController();
            Get.put<MainController>(controller);
            dynamicCallsDuringBuild = controller.dynamicCalls;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(dynamicCallsDuringBuild, 0);
    expect(controller.dynamicCalls, 1);

    await tester.pump();
    expect(controller.dynamicCalls, 1);
    controller.checkUnreadDynamic();
    expect(controller.dynamicCalls, 1);
  });

  testWidgets('deferred requests do not wait for a pending message response', (
    tester,
  ) async {
    final pending = Completer<void>();
    late _CountingMainController controller;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (_) {
            controller = _CountingMainController()..messageResponse = pending;
            Get.put<MainController>(controller);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(controller.dynamicCalls, 1);
    expect(controller.messageCalls, 1);
    await tester.pump();
    expect(controller.dynamicCalls, 1);
    expect(controller.messageCalls, 1);
    pending.complete();
    await tester.pump();
  });
}

// 仅替换请求出口；使用真实 MainController 初始化、导航与 GetX 生命周期。
class _CountingMainController extends MainController {
  int dynamicCalls = 0;
  int messageCalls = 0;
  Completer<void>? messageResponse;
  final phases = <SchedulerPhase>[];

  @override
  void getUnreadDynamic() {
    dynamicCalls++;
    phases.add(SchedulerBinding.instance.schedulerPhase);
  }

  @override
  Future<void> queryUnreadMsg([bool isChangeType = false]) {
    messageCalls++;
    phases.add(SchedulerBinding.instance.schedulerPhase);
    return messageResponse?.future ?? Future<void>.value();
  }
}
