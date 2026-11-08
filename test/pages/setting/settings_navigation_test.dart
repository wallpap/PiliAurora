import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/setting_type.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/pages/setting/common_setting.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/models/content_settings.dart';
import 'package:pili_aurora/models/common/reply/reply_level_filter.dart';
import 'package:pili_aurora/pages/setting/models/play_settings.dart';
import 'package:pili_aurora/pages/setting/models/privacy_settings.dart';
import 'package:pili_aurora/pages/setting/models/video_settings.dart';
import 'package:pili_aurora/pages/setting/view.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import '../../support/memory_box.dart';

void main() {
  final settings = MemoryBox();
  setUpAll(() {
    GStorage.setting = settings;
    GStorage.video = MemoryBox();
  });
  setUp(settings.data.clear);
  tearDown(Get.reset);

  testWidgets('评论等级默认关闭，选择后保存并可恢复关闭', (tester) async {
    final group = contentSettings.whereType<SettingsGroup>().firstWhere(
      (group) => group.title == '内容过滤',
    );
    final item = group.children
        .whereType<PopupModel<ReplyLevelFilter>>()
        .single;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: item.widget)));
    expect(Pref.minimumReplyUserLevel, 0);
    await tester.tap(find.text('最低评论用户等级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lv4 及以上'));
    await tester.pumpAndSettle();
    expect(Pref.minimumReplyUserLevel, 4);
    await tester.tap(find.text('最低评论用户等级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不屏蔽'));
    await tester.pumpAndSettle();
    expect(Pref.minimumReplyUserLevel, 0);
  });

  test('损坏或越界的评论等级设置回退为关闭', () async {
    for (final value in [-1, 7, '4', null]) {
      await settings.put(SettingBoxKey.minimumReplyUserLevel, value);
      expect(Pref.minimumReplyUserLevel, 0);
    }
  });

  testWidgets('黑名单父子开关默认开启，父开关切换后保留子项选择', (tester) async {
    final item = privacySettings.whereType<SwitchModel>().single;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: item.widget)));
    expect(Pref.filterBlockedAuthors, isTrue);
    expect(Pref.checkCooperativeAuthors, isTrue);
    expect(find.text('检查合作视频作者'), findsOneWidget);
    await tester.tap(find.text('检查合作视频作者'));
    await tester.pumpAndSettle();
    expect(Pref.checkCooperativeAuthors, isFalse);
    expect(Pref.filterBlockedAuthors, isTrue);
    await tester.tap(find.text('增强黑名单屏蔽'));
    await tester.pumpAndSettle();
    expect(Pref.filterBlockedAuthors, isFalse);
    expect(find.text('检查合作视频作者'), findsNothing);
    await tester.tap(find.text('增强黑名单屏蔽'));
    await tester.pumpAndSettle();
    expect(Pref.filterBlockedAuthors, isTrue);
    expect(Pref.checkCooperativeAuthors, isFalse);
    expect(find.text('检查合作视频作者'), findsOneWidget);
  });

  testWidgets('高能进度条颜色支持保存、取消与恢复主题', (tester) async {
    final item = playProgressExtraSettings.whereType<NormalModel>().single;
    await tester.pumpWidget(
      GetMaterialApp(home: Scaffold(body: item.widget)),
    );
    expect(find.text('跟随主题'), findsOneWidget);
    await tester.tap(find.text('高能进度条颜色'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(Pref.dmChartColor, const Color(0xFF123456));
    expect(find.text('#123456'), findsOneWidget);

    await tester.tap(find.text('高能进度条颜色'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ABCDEF');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(Pref.dmChartColor, const Color(0xFF123456));

    await tester.tap(find.text('高能进度条颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();
    expect(Pref.dmChartColor, isNull);
    expect(find.text('跟随主题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面分类切换显示对应设置内容', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingPage()));
    expect(find.text('切换账号'), findsNothing);
    expect(find.text('退出登录'), findsNothing);

    await tester.tap(find.text('账号与隐私'));
    await tester.pumpAndSettle();
    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('了解账号模式'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'CDN order appears when enabled, saves click order and resets to default',
    (tester) async {
      final fallback = videoSettings
          .expand((item) => item.searchableItems)
          .whereType<SwitchModel>()
          .singleWhere((item) => item.setKey == SettingBoxKey.enableMultiCdn);
      await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: fallback.widget)),
      );
      expect(find.text('CDN 回退顺序'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(Pref.enableMultiCdn, isTrue);
      expect(find.text('CDN 回退顺序'), findsOneWidget);
      expect(find.textContaining('默认按 CDN 列表顺序'), findsOneWidget);
      for (final expected in [
        [CDNService.cos, CDNService.ali],
        <CDNService>[],
      ]) {
        await tester.tap(find.text('CDN 回退顺序'));
        await tester.pumpAndSettle();
        for (final service in [CDNService.cos, CDNService.ali]) {
          final option = find.text(service.desc);
          await tester.ensureVisible(option);
          await tester.tap(option);
          await tester.pump();
        }
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(Pref.cdnFallbackOrder, expected);
      }
      expect(find.textContaining('默认按 CDN 列表顺序'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('CDN 回退顺序'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('categories open subpages and restore the parent on back', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CommonSetting(settingType: SettingType.videoSetting),
      ),
    );
    expect(find.text('默认画质'), findsNothing);
    await tester.tap(find.text('画质与音质'));
    await tester.pumpAndSettle();
    expect(find.text('默认画质'), findsOneWidget);
    expect(find.text('首选解码格式'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('播放线路'), findsOneWidget);
    expect(find.text('默认画质'), findsNothing);
    await tester.tap(find.text('解码与输出'));
    await tester.pumpAndSettle();
    expect(find.text('首选解码格式'), findsOneWidget);
    expect(find.text('蜂窝网络首选解码格式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded category switching replaces the settings tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CommonSetting(
          settingType: SettingType.videoSetting,
          showAppBar: false,
        ),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: CommonSetting(
          settingType: SettingType.contentSetting,
          showAppBar: false,
        ),
      ),
    );
    expect(find.text('画质与音质'), findsNothing);
    expect(find.text('搜索与发现'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
