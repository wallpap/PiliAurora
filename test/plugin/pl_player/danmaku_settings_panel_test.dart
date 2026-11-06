import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/video/widgets/header_mixin.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

void main() {
  setUpAll(() {
    GStorage.setting = _Settings();
    GStorage.video = _Settings();
  });

  for (final scenario in [
    (size: const Size(390, 844), fullscreen: false),
    (size: const Size(844, 390), fullscreen: true),
    (size: const Size(1280, 800), fullscreen: false),
  ]) {
    testWidgets('点播面板 ${scenario.size} fullscreen=${scenario.fullscreen}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 24,
        right: 24,
        bottom: 16,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(Get.reset);
      DanmakuOptions.danmakuShowArea = .8;
      DanmakuOptions.blockTypes.clear();
      addTearDown(DanmakuOptions.blockTypes.clear);
      await GStorage.setting.put(SettingBoxKey.danmakuFrameRate, 0);
      await GStorage.setting.put(SettingBoxKey.mergeDanmakuThreshold, 7);
      final controller = _Controller().._fullScreen.value = scenario.fullscreen;
      await tester.pumpWidget(GetMaterialApp(home: _Host(controller)));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final reset = find.byTooltip('恢复默认值：50.0%', skipOffstage: false);
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(DanmakuOptions.danmakuShowArea, .5);
      await tester.tap(find.text('屏蔽'));
      await tester.pumpAndSettle();
      final types = [
        '滚动',
        '顶部',
        '底部',
        '彩色',
        '高级',
      ].map((label) => find.widgetWithText(FilterChip, label)).toList();
      await tester.tap(types.first);
      await tester.pumpAndSettle();
      expect(DanmakuOptions.blockTypes, contains(2));
      expect(find.widgetWithText(ChoiceChip, '30 FPS'), findsNothing);
      final fps = find.widgetWithText(ChoiceChip, '60 FPS');
      expect(fps, findsNothing);
      await tester.tap(find.text('运动'));
      await tester.pumpAndSettle();
      if (Platform.isWindows) {
        expect(fps, findsNothing);
        expect(find.text('弹幕帧率（实验性）'), findsNothing);
      } else {
        expect(find.widgetWithText(ChoiceChip, '30 FPS'), findsNothing);
        await tester.ensureVisible(fps);
        await tester.pumpAndSettle();
        await tester.tap(fps);
        await tester.pumpAndSettle();
        expect(Pref.danmakuFrameRate, 60);
      }
      await tester.tap(find.text('屏蔽'));
      await tester.pumpAndSettle();
      final threshold = find.descendant(
        of: find.byKey(const ValueKey('danmaku-放大阈值')),
        matching: find.byType(Slider),
      );
      await tester.scrollUntilVisible(
        threshold,
        80,
        continuous: true,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('danmaku-filtering')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(threshold);
      await tester.pumpAndSettle();
      expect(Pref.mergeDanmakuThreshold, greaterThan(7));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置'), findsNothing);
    });
  }

  testWidgets('直播提供类型屏蔽和行内帧率，省略点播合并选项', (tester) async {
    addTearDown(Get.reset);
    await tester.pumpWidget(
      GetMaterialApp(home: _Host(_Controller(), isLive: true)),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, '滚动'), findsOneWidget);
    if (Platform.isWindows) {
      expect(find.text('性能'), findsNothing);
      expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(2));
      await tester.tap(find.text('运动'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕帧率（实验性）'), findsNothing);
    } else {
      await tester.tap(find.text('性能'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '30 FPS'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '60 FPS'));
      await tester.pumpAndSettle();
      expect(Pref.danmakuFrameRate, 60);
    }
    expect(find.text('合并弹幕'), findsNothing);
    expect(find.text('智能云屏蔽'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Host extends StatefulWidget {
  const _Host(this.controller, {this.isLive = false});
  final PlPlayerController controller;
  final bool isLive;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with HeaderMixin<_Host> {
  @override
  PlPlayerController get plPlayerController => widget.controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => showSetDanmaku(isLive: widget.isLive),
        child: const Text('打开'),
      ),
    ),
  );
}

class _Controller implements PlPlayerController {
  final _fullScreen = false.obs;
  final _opacity = .65.obs;
  @override
  void notifyDanmakuOptionsChanged() {}
  @override
  void refreshDanmakuRules() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      switch (invocation.memberName) {
        #isFullScreen => _fullScreen,
        #danmakuOpacity => _opacity,
        #danmakuController => null,
        #darkVideoPage => false,
        #filters => RuleFilter([], [], {}),
        _ => super.noSuchMethod(invocation),
      };
}

class _Settings implements Box<dynamic> {
  final _values = <dynamic, dynamic>{};
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => _values[key] = value;
  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async =>
      _values.addAll(entries);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
