import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/setting_type.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/pages/setting/common_setting.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/models/video_settings.dart';
import 'package:pili_aurora/pages/setting/view.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

void main() {
  final settings = _DefaultSettings();
  setUpAll(() {
    GStorage.setting = settings;
    GStorage.video = _DefaultSettings();
  });
  setUp(settings._values.clear);
  tearDown(Get.reset);

  testWidgets('landscape search stays inside the category list', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingPage()));
    final search = tester.getRect(find.widgetWithText(InkWell, ' 搜索'));
    final category = tester.getRect(find.text('推荐与过滤'));
    final subcategory = tester.getRect(find.text('主题与文字'));
    expect(search.left, 16);
    expect(search.right, lessThan(subcategory.left));
    expect(search.bottom, lessThan(category.top));
    expect(find.text('切换账号'), findsNothing);
    expect(find.text('退出登录'), findsNothing);

    await tester.tap(find.text('账号与隐私'));
    await tester.pumpAndSettle();
    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('了解账号模式'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait search scrolls with the categories', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingPage()));
    final search = tester.getRect(find.widgetWithText(InkWell, ' 搜索'));
    expect(search.width, 368);
    final top = search.top;
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    scrollable.position.jumpTo(16);
    await tester.pump();
    expect(
      tester.getRect(find.widgetWithText(InkWell, ' 搜索')).top,
      top - 16,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'CDN order appears when enabled, saves click order and resets to default',
    (tester) async {
      final fallback = videoSettings
          .expand((item) => item.searchableItems)
          .whereType<SwitchModel>()
          .singleWhere((item) => item.setKey == SettingBoxKey.enableMultiCdn);
      expect(fallback.title, contains('实验性功能'));
      await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: fallback.widget)),
      );
      expect(find.text('CDN 回退顺序'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(Pref.enableMultiCdn, isTrue);
      expect(find.text('CDN 回退顺序'), findsOneWidget);
      expect(find.textContaining('默认按 CDN 列表顺序'), findsOneWidget);
      await tester.tap(find.text('CDN 回退顺序'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(CDNService.cos.desc));
      await tester.tap(find.text(CDNService.cos.desc));
      await tester.pump();
      await tester.ensureVisible(find.text(CDNService.ali.desc));
      await tester.tap(find.text(CDNService.ali.desc));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(Pref.cdnFallbackOrder, [CDNService.cos, CDNService.ali]);

      await tester.tap(find.text('CDN 回退顺序'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(CDNService.cos.desc));
      await tester.tap(find.text(CDNService.cos.desc));
      await tester.pump();
      await tester.ensureVisible(find.text(CDNService.ali.desc));
      await tester.tap(find.text(CDNService.ali.desc));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(Pref.cdnFallbackOrder, isEmpty);
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

  testWidgets(
    'volume belongs to playback behavior while slide controls stay under gestures',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CommonSetting(settingType: SettingType.playSetting),
        ),
      );
      await tester.tap(find.text('手势与键盘'));
      await tester.pumpAndSettle();
      expect(find.text('左右侧滑动调节亮度/音量'), findsOneWidget);
      expect(find.text('最高音量'), findsNothing);
      expect(find.text('播放器音量'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放行为'));
      await tester.pumpAndSettle();
      expect(find.text('最高音量'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

// 导航测试在内存中保存偏好，包含桌面布局的默认值初始化。
class _DefaultSettings implements Box<dynamic> {
  final _values = <dynamic, dynamic>{};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async => _values[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
