import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart'
    hide StatefulBuilder, RefreshIndicator;
import 'package:pili_aurora/common/widgets/color_palette.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/emote_tooltip.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart'
    show RefreshIndicator, displacement, refreshDragExtent;
import 'package:pili_aurora/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart'
    show deviceTouchSlop, touchSlopH;
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/image_grid/image_grid_view.dart'
    show ImageGridView, ImageModel;
import 'package:pili_aurora/common/widgets/pendant_avatar.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show kSpringDescription;
import 'package:pili_aurora/common/widgets/stateful_builder.dart';
import 'package:pili_aurora/models/common/bar_hide_type.dart';
import 'package:pili_aurora/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:pili_aurora/models/common/dynamic/up_panel_position.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/models/common/theme/theme_color_type.dart';
import 'package:pili_aurora/models/common/theme/theme_type.dart';
import 'package:pili_aurora/pages/common/slide/common_slide_page.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/mine/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/slide_color_picker.dart';
import 'package:pili_aurora/pages/setting/widgets/dual_slider_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/multi_select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/slider_dialog.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/filtering_text.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

List<SettingsModel> get styleSettings => [
  SettingsGroup(
    title: '主题与文字',
    subtitle: '主题颜色、字体与界面缩放',
    leading: const Icon(Icons.palette_outlined),
    children: [
      NormalModel(
        title: 'App字体设置',
        subtitle: '点击设置',
        leading: const Icon(Icons.text_fields),
        onTap: (context, setState) => Get.toNamed('/fontSetting'),
      ),
      NormalModel(
        title: '界面缩放',
        getSubtitle: () => '当前缩放比例：${Pref.uiScale.toStringAsFixed(2)}',
        leading: const Icon(Icons.zoom_in_outlined),
        onTap: _showUiScaleDialog,
      ),
      const SwitchModel(
        title: '视频播放页使用深色主题',
        leading: Icon(Icons.dark_mode_outlined),
        setKey: SettingBoxKey.darkVideoPage,
        defaultVal: false,
      ),
      NormalModel(
        leading: const Icon(Icons.opacity_outlined),
        title: '气泡提示不透明度',
        subtitle: '自定义气泡提示(Toast)不透明度',
        getTrailing: (theme) => Text(
          CustomToast.toastOpacity.toStringAsFixed(1),
          style: theme.textTheme.titleSmall,
        ),
        onTap: _showToastDialog,
      ),
      PopupModel(
        leading: const Icon(Icons.flashlight_on_outlined),
        title: '主题模式',
        value: () => Pref.themeType,
        items: ThemeType.values,
        onSelected: _setThemeType,
      ),
      SwitchModel(
        leading: const Icon(Icons.invert_colors),
        title: '纯黑主题',
        setKey: SettingBoxKey.isPureBlackTheme,
        defaultVal: false,
        onChanged: (value) {
          if (ThemeUtils.isDarkMode || Pref.darkVideoPage) {
            Get.updateMyAppTheme();
          }
        },
      ),
      NormalModel(
        onTap: (context, setState) => Get.toNamed('/colorSetting'),
        leading: const Icon(Icons.color_lens_outlined),
        title: '应用主题',
        getSubtitle: () => '当前主题：${Pref.dynamicColor ? '动态取色' : '指定颜色'}',
        getTrailing: (theme) {
          if (Pref.dynamicColor) {
            return Icon(
              Icons.color_lens_rounded,
              color: theme.colorScheme.primary,
            );
          }
          final customColor = Pref.customColor;
          final color =
              colorThemeTypes.elementAtOrNull(customColor)?.color ??
              Color(customColor);
          return SizedBox.square(
            dimension: 20,
            child: ColorPalette(
              colorScheme: color.asColorSchemeSeed(
                Pref.schemeVariant,
                theme.brightness,
              ),
              selected: false,
              showBgColor: false,
            ),
          );
        },
      ),
    ],
  ),
  SettingsGroup(
    title: '布局与导航',
    subtitle: '首页、导航栏、横屏与窗口',
    leading: const Icon(Icons.dashboard_outlined),
    children: [
      if (PlatformUtils.isDesktop) ...[
        const SwitchModel(
          title: '显示窗口标题栏',
          leading: Icon(Icons.window),
          setKey: SettingBoxKey.showWindowTitleBar,
          defaultVal: true,
          needReboot: true,
        ),
        const SwitchModel(
          title: '显示托盘图标',
          leading: Icon(Icons.donut_large_rounded),
          setKey: SettingBoxKey.showTrayIcon,
          defaultVal: true,
          needReboot: true,
        ),
      ],
      SwitchModel(
        title: '横屏适配',
        subtitle: '启用横屏布局与逻辑，平板、折叠屏等可开启；建议全屏方向设为【不改变当前方向】',
        leading: const Icon(Icons.phonelink_outlined),
        setKey: SettingBoxKey.horizontalScreen,
        defaultVal: Pref.horizontalScreen,
        onChanged: (value) {
          if (value) {
            fullMode();
          } else {
            portraitUpMode();
          }
        },
      ),
      const SwitchModel(
        title: '改用侧边栏',
        subtitle: '开启后底栏与顶栏被替换，且相关设置失效',
        leading: Icon(Icons.chrome_reader_mode_outlined),
        setKey: SettingBoxKey.useSideBar,
        defaultVal: false,
        needReboot: true,
      ),
      const SwitchModel(
        title: '优化平板导航栏',
        leading: Icon(Icons.auto_fix_high),
        setKey: SettingBoxKey.optTabletNav,
        defaultVal: true,
        needReboot: true,
      ),
      const SwitchModel(
        title: 'MD3样式底栏',
        subtitle: 'Material You设计规范底栏，关闭可变窄',
        leading: Icon(Icons.design_services_outlined),
        setKey: SettingBoxKey.enableMYBar,
        defaultVal: true,
        needReboot: true,
      ),
      const SwitchModel(
        title: '悬浮底栏',
        leading: Icon(MdiIcons.soundbar),
        setKey: SettingBoxKey.floatingNavBar,
        defaultVal: false,
        needReboot: true,
      ),
      NormalModel(
        leading: const Icon(Icons.calendar_view_week_outlined),
        title: '列表宽度（dp）限制',
        getSubtitle: () =>
            '当前: 主页${Pref.recommendCardWidth.toInt()}dp 其他${Pref.smallCardWidth.toInt()}dp，屏幕宽度:${MediaQuery.widthOf(Get.context!).toPrecision(2)}dp。宽度越小列数越多。',
        onTap: _showCardWidthDialog,
      ),
      const SwitchModel(
        title: '播放页移除安全边距',
        leading: Icon(Icons.fit_screen_outlined),
        setKey: SettingBoxKey.removeSafeArea,
        defaultVal: false,
      ),
      PopupModel(
        title: '顶/底栏收起类型',
        leading: const Icon(MdiIcons.arrowExpandVertical),
        value: () => Pref.barHideType,
        items: BarHideType.values,
        onSelected: (value, setState) {
          GStorage.setting
              .put(SettingBoxKey.barHideType, value.index)
              .whenComplete(setState);
          SmartDialog.showToast('重启生效');
        },
      ),
      SwitchModel(
        title: '首页顶栏收起',
        subtitle: '首页列表滑动时，收起顶栏',
        leading: const Icon(Icons.vertical_align_top_outlined),
        setKey: SettingBoxKey.hideTopBar,
        defaultVal: PlatformUtils.isMobile,
        needReboot: true,
      ),
      SwitchModel(
        title: '首页底栏收起',
        subtitle: '首页列表滑动时，收起底栏',
        leading: const Icon(Icons.vertical_align_bottom_outlined),
        setKey: SettingBoxKey.hideBottomBar,
        defaultVal: PlatformUtils.isMobile,
        needReboot: true,
      ),
      PopupModel(
        leading: const Icon(Icons.home_outlined),
        title: '默认启动页',
        value: () => Pref.defaultHomePage,
        items: NavigationBarType.values,
        onSelected: (value, setState) {
          GStorage.setting
              .put(SettingBoxKey.defaultHomePage, value.index)
              .whenComplete(setState);
          SmartDialog.showToast('重启生效');
        },
      ),
      NormalModel(
        onTap: (context, setState) => Get.toNamed(
          '/barSetting',
          arguments: {
            'key': SettingBoxKey.tabBarSort,
            'defaultBars': HomeTabType.values,
            'title': '首页标签页',
          },
        ),
        title: '首页标签页',
        subtitle: '删除或调换首页标签页',
        leading: const Icon(Icons.toc_outlined),
      ),
      NormalModel(
        onTap: (context, setState) => Get.toNamed(
          '/barSetting',
          arguments: {
            'key': SettingBoxKey.navBarSort,
            'defaultBars': NavigationBarType.values,
            'title': 'Navbar',
          },
        ),
        title: 'Navbar编辑',
        subtitle: '删除或调换Navbar',
        leading: const Icon(Icons.toc_outlined),
      ),
      SwitchModel(
        title: '返回时直接退出',
        subtitle: '开启后在主页任意tab按返回键都直接退出，关闭则先回到Navbar的第一个tab',
        leading: const Icon(Icons.exit_to_app_outlined),
        setKey: SettingBoxKey.directExitOnBack,
        defaultVal: false,
        onChanged: (value) =>
            Get.find<MainController>().directExitOnBack = value,
      ),
    ],
  ),
  SettingsGroup(
    title: '动态与消息提示',
    subtitle: '动态布局、未读标记与消息提示',
    leading: const Icon(Icons.notifications_outlined),
    children: [
      SwitchModel(
        title: '动态页启用瀑布流',
        subtitle: '关闭会显示为单列',
        leading: const Icon(Icons.view_array_outlined),
        setKey: SettingBoxKey.dynamicsWaterfallFlow,
        defaultVal: Pref.horizontalScreen,
        needReboot: true,
      ),
      PopupModel(
        title: '动态页UP主显示位置',
        leading: const Icon(Icons.person_outlined),
        value: () => Pref.upPanelPosition,
        items: UpPanelPosition.values,
        onSelected: (value, setState) {
          GStorage.setting
              .put(SettingBoxKey.upPanelPosition, value.index)
              .whenComplete(setState);
          SmartDialog.showToast('重启生效');
        },
      ),
      const SwitchModel(
        title: '动态页显示所有已关注UP主',
        leading: Icon(Icons.people_alt_outlined),
        setKey: SettingBoxKey.dynamicsShowAllFollowedUp,
        defaultVal: false,
        needReboot: true,
      ),
      const SwitchModel(
        title: '动态页展开正在直播UP列表',
        leading: Icon(Icons.live_tv),
        setKey: SettingBoxKey.expandDynLivePanel,
        defaultVal: false,
        needReboot: true,
      ),
      PopupModel(
        title: '动态未读标记',
        leading: const Icon(Icons.motion_photos_on_outlined),
        value: () => Pref.dynamicBadgeType,
        items: DynamicBadgeMode.values,
        onSelected: _setDynBadge,
      ),
      PopupModel(
        title: '消息未读标记',
        leading: const Icon(MdiIcons.bellBadgeOutline),
        value: () => Pref.msgBadgeMode,
        items: DynamicBadgeMode.values,
        onSelected: _setMsgBadge,
      ),
      NormalModel(
        onTap: _showMsgUnReadDialog,
        title: '消息未读类型',
        leading: const Icon(MdiIcons.bellCogOutline),
        getSubtitle: () =>
            '当前消息类型：${Pref.msgUnReadTypeV2.map((item) => item.title).join('、')}',
      ),
    ],
  ),
  SettingsGroup(
    title: '图片、动效与交互',
    subtitle: '图片质量、动画与帧率',
    leading: const Icon(Icons.image_outlined),
    children: [
      ...appearanceExtraSettings,
      NormalModel(
        title: '页面过渡动画',
        leading: const Icon(Icons.animation),
        getSubtitle: () => '当前：${Pref.pageTransition.name}',
        onTap: _showTransitionDialog,
      ),
      NormalModel(
        onTap: (context, setState) => _showQualityDialog(
          context: context,
          title: const Text('图片质量'),
          initValue: Pref.picQuality,
          onChanged: (picQuality) async {
            GlobalData().imgQuality = picQuality;
            await GStorage.setting.put(SettingBoxKey.defaultPicQa, picQuality);
            setState();
          },
        ),
        title: '图片质量',
        subtitle: '选择合适的图片清晰度，上限100%',
        leading: const Icon(Icons.image_outlined),
        getTrailing: (theme) => Text(
          '${Pref.picQuality}%',
          style: theme.textTheme.titleSmall,
        ),
      ),
      NormalModel(
        onTap: (context, setState) => _showQualityDialog(
          context: context,
          title: const Text('查看大图质量'),
          initValue: Pref.previewQ,
          onChanged: (picQuality) async {
            await GStorage.setting.put(
              SettingBoxKey.previewQuality,
              picQuality,
            );
            setState();
          },
        ),
        title: '查看大图质量',
        subtitle: '选择合适的图片清晰度，上限100%',
        leading: const Icon(Icons.image_outlined),
        getTrailing: (theme) => Text(
          '${Pref.previewQ}%',
          style: theme.textTheme.titleSmall,
        ),
      ),
      NormalModel(
        onTap: _showReduceColorDialog,
        title: '深色下图片颜色叠加',
        subtitle: '显示颜色=图片原色x所选颜色，大图查看不受影响',
        leading: const Icon(Icons.format_color_fill_outlined),
        getTrailing: (theme) => Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Pref.reduceLuxColor ?? Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
      const NormalModel(
        title: '滑动动画弹簧参数',
        leading: Icon(Icons.chrome_reader_mode_outlined),
        onTap: _showSpringDialog,
      ),
      if (Platform.isAndroid)
        NormalModel(
          onTap: (context, setState) => Get.toNamed('/displayModeSetting'),
          title: '屏幕帧率',
          leading: const Icon(Icons.autofps_select_outlined),
        ),
    ],
  ),
];

void _showQualityDialog({
  required BuildContext context,
  required Widget title,
  required int initValue,
  required ValueChanged<int> onChanged,
}) {
  showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      value: initValue.toDouble(),
      title: title,
      min: 10,
      max: 100,
      divisions: 9,
      suffix: '%',
      precise: 0,
    ),
  ).then((result) {
    if (result != null) {
      SmartDialog.showToast('设置成功');
      onChanged(result.toInt());
    }
  });
}

void _showUiScaleDialog(
  BuildContext context,
  VoidCallback setState,
) {
  const minUiScale = 0.5;
  const maxUiScale = 2.0;

  double uiScale = Pref.uiScale;
  final textController = TextEditingController(
    text: uiScale.toStringAsFixed(2),
  );

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('界面缩放'),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      content: StatefulBuilder(
        onDispose: textController.dispose,
        builder: (context, setDialogState) => Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              padding: .zero,
              value: uiScale,
              min: minUiScale,
              max: maxUiScale,
              secondaryTrackValue: 1.0,
              divisions: ((maxUiScale - minUiScale) * 20).toInt(),
              label: textController.text,
              onChanged: (value) => setDialogState(() {
                uiScale = value.toPrecision(2);
                textController.text = uiScale.toStringAsFixed(2);
              }),
            ),
            TextFormField(
              controller: textController,
              keyboardType: const .numberWithOptions(decimal: true),
              inputFormatters: [
                LengthLimitingTextInputFormatter(4),
                FilteringTextInputFormatter.allow(RegExp(r'[\d.]+')),
              ],
              decoration: const InputDecoration(
                labelText: '缩放比例',
                hintText: '0.50 - 2.00',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                final parsed = double.tryParse(value);
                if (parsed != null &&
                    parsed >= minUiScale &&
                    parsed <= maxUiScale) {
                  setDialogState(() {
                    uiScale = parsed;
                  });
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            GStorage.setting.delete(SettingBoxKey.uiScale).whenComplete(() {
              setState();
              Get.appUpdate();
              ScaledWidgetsFlutterBinding.instance.scaleFactor = 1.0;
            });
          },
          child: const Text('重置'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            GStorage.setting.put(SettingBoxKey.uiScale, uiScale).whenComplete(
              () {
                setState();
                Get.appUpdate();
                ScaledWidgetsFlutterBinding.instance.scaleFactor = uiScale;
              },
            );
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _showSpringDialog(BuildContext context, _) {
  final List<String> springDescription = Pref.springDescription
      .map((i) => i.toString())
      .toList(growable: false);
  bool physicalMode = true;

  void physical2Duration() {
    final mass = double.parse(springDescription[0]);
    final stiffness = double.parse(springDescription[1]);
    final damping = double.parse(springDescription[2]);

    final duration = math.sqrt(4 * math.pi * math.pi * mass / stiffness);
    final dampingRatio = damping / (2.0 * math.sqrt(mass * stiffness));
    final bounce = dampingRatio < 1.0
        ? 1.0 - dampingRatio
        : 1.0 / dampingRatio - 1;

    springDescription[0] = duration.toString();
    springDescription[1] = bounce.toString();
  }

  /// from [SpringDescription.withDurationAndBounce] but with higher precision
  void duration2Physical() {
    final duration = double.parse(springDescription[0]);
    final bounce = double.parse(springDescription[1]).clamp(-1.0, 1.0);

    final stiffness = 4 * math.pi * math.pi / math.pow(duration, 2);
    final dampingRatio = bounce > 0 ? 1.0 - bounce : 1.0 / (bounce + 1);
    final damping = 2 * math.sqrt(stiffness) * dampingRatio;

    springDescription[0] = '1';
    springDescription[1] = stiffness.toString();
    springDescription[2] = damping.toString();
  }

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        mainAxisAlignment: .spaceBetween,
        children: [
          const Text('弹簧参数'),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: .compact,
              tapTargetSize: .shrinkWrap,
            ),
            onPressed: () {
              try {
                if (physicalMode) {
                  physical2Duration();
                } else {
                  duration2Physical();
                }
                physicalMode = !physicalMode;
                (context as Element).markNeedsBuild();
              } catch (e) {
                SmartDialog.showToast(e.toString());
              }
            },
            child: Text(physicalMode ? '滑动时间' : '物理参数'),
          ),
        ],
      ),
      content: Column(
        key: ValueKey(physicalMode),
        mainAxisSize: .min,
        children: List.generate(
          physicalMode ? 3 : 2,
          (index) => TextFormField(
            autofocus: index == 0,
            initialValue: springDescription[index],
            keyboardType: .numberWithOptions(
              signed: !physicalMode && index == 1,
              decimal: true,
            ),
            onChanged: (value) => springDescription[index] = value,
            inputFormatters: [
              !physicalMode && index == 1
                  ? FilteringTextInputFormatter.allow(RegExp(r'[-\d\.]+'))
                  : FilteringTextInputFormatter.allow(RegExp(r'[\d\.]+')),
            ],
            decoration: InputDecoration(
              labelText: (physicalMode
                  ? const ['mass', 'stiffness', 'damping']
                  : const ['duration', 'bounce'])[index],
              suffixText: !physicalMode && index == 0 ? 's' : null,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Get.back();
            GStorage.setting.delete(SettingBoxKey.springDescription);
            SmartDialog.showToast('重置成功，重启生效');
          },
          child: const Text('重置'),
        ),
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () {
            try {
              if (!physicalMode) {
                duration2Physical();
              }
              final res = springDescription.map(double.parse).toList();
              Get.back();
              GStorage.setting.put(SettingBoxKey.springDescription, res);
              kSpringDescription = SpringDescription(
                mass: res[0],
                stiffness: res[1],
                damping: res[2],
              );
              SmartDialog.showToast('设置成功');
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<void> _showTransitionDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<Transition>(
    context: context,
    builder: (context) => SelectDialog<Transition>(
      title: '页面过渡动画',
      value: Pref.pageTransition,
      values: Transition.values.map((e) => (e, e.name)).toList(),
    ),
  );
  if (res != null) {
    Get.rootController.defaultTransition = res;
    await GStorage.setting.put(SettingBoxKey.pageTransition, res.index);
    setState();
  }
}

Future<void> _showCardWidthDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<(double, double)>(
    context: context,
    builder: (context) => DualSliderDialog(
      title: const Text('列表最大列宽度（默认240dp）'),
      value1: Pref.recommendCardWidth,
      value2: Pref.smallCardWidth,
      description1: const Text('主页推荐流'),
      description2: const Text('其他'),
      min: 150.0,
      max: 500.0,
      divisions: 35,
      suffix: 'dp',
    ),
  );
  if (res != null) {
    await GStorage.setting.putAll({
      SettingBoxKey.recommendCardWidth: res.$1,
      SettingBoxKey.smallCardWidth: res.$2,
    });
    SmartDialog.showToast('重启生效');
    setState();
  }
}

void _setDynBadge(DynamicBadgeMode value, VoidCallback setState) {
  final mainController = Get.find<MainController>()..dynamicBadgeMode = value;
  if (value != DynamicBadgeMode.hidden) mainController.getUnreadDynamic();
  GStorage.setting
      .put(SettingBoxKey.dynamicBadgeMode, value.index)
      .whenComplete(setState);
}

Future<void> _setMsgBadge(DynamicBadgeMode value, VoidCallback setState) async {
  final mainController = Get.find<MainController>()..msgBadgeMode = value;
  if (value != DynamicBadgeMode.hidden) {
    mainController.queryUnreadMsg(true);
  } else {
    mainController.clearUnreadMsg();
  }
  GStorage.setting
      .put(SettingBoxKey.msgBadgeMode, value.index)
      .whenComplete(setState);
}

Future<void> _showMsgUnReadDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<Set<MsgUnReadType>>(
    context: context,
    builder: (context) => MultiSelectDialog<MsgUnReadType>(
      title: '消息未读类型',
      initValues: Pref.msgUnReadTypeV2,
      values: {for (final i in MsgUnReadType.values) i: i.title},
    ),
  );
  if (res != null) {
    final mainController = Get.find<MainController>()..msgUnReadTypes = res;
    if (mainController.msgBadgeMode != DynamicBadgeMode.hidden) {
      mainController.queryUnreadMsg();
    }
    await GStorage.setting.put(
      SettingBoxKey.msgUnReadTypeV2,
      res.map((item) => item.index).toList()..sort(),
    );
    SmartDialog.showToast('设置成功');
    setState();
  }
}

void _showReduceColorDialog(
  BuildContext context,
  VoidCallback setState,
) {
  final reduceLuxColor = Pref.reduceLuxColor;
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      clipBehavior: Clip.hardEdge,
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      title: const Text('Color Picker'),
      content: SlideColorPicker(
        color: reduceLuxColor ?? Colors.white,
        onChanged: (Color? color) {
          if (color != null && color != reduceLuxColor) {
            if (color == Colors.white) {
              NetworkImgLayer.reduceLuxColor = null;
              GStorage.setting.delete(SettingBoxKey.reduceLuxColor);
              SmartDialog.showToast('设置成功');
              setState();
            } else {
              void onConfirm() {
                NetworkImgLayer.reduceLuxColor = color;
                GStorage.setting.put(
                  SettingBoxKey.reduceLuxColor,
                  color.toARGB32(),
                );
                SmartDialog.showToast('设置成功');
                setState();
              }

              if (color.computeLuminance() < 0.2) {
                showConfirmDialog(
                  context: context,
                  title: Text(
                    '确认使用#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6)}？',
                  ),
                  content: const Text('所选颜色过于昏暗，可能会影响图片观看'),
                  onConfirm: onConfirm,
                );
              } else {
                onConfirm();
              }
            }
          }
        },
      ),
    ),
  );
}

Future<void> _showToastDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('Toast不透明度'),
      value: CustomToast.toastOpacity,
      min: 0.0,
      max: 1.0,
      divisions: 10,
    ),
  );
  if (res != null) {
    CustomToast.toastOpacity = res;
    await GStorage.setting.put(SettingBoxKey.defaultToastOp, res);
    SmartDialog.showToast('设置成功');
    setState();
  }
}

void _setThemeType(ThemeType value, VoidCallback setState) {
  try {
    Get.find<MineController>().themeType.value = value;
  } catch (_) {}
  GStorage.setting.put(SettingBoxKey.themeMode, value.index);
  Get.changeThemeMode(ThemeUtils.themeMode = value.toThemeMode);
  setState();
}

List<SettingsModel> get appearanceExtraSettings => [
  SwitchModel(
    title: '横屏在侧栏打开图片预览',
    leading: const Icon(Icons.photo_outlined),
    setKey: SettingBoxKey.horizontalPreview,
    defaultVal: false,
    onChanged: (value) => ImageGridView.horizontalPreview = value,
  ),
  const SwitchModel(
    title: '使用外部浏览器打开链接',
    leading: Icon(Icons.open_in_browser),
    setKey: SettingBoxKey.openInBrowser,
    defaultVal: false,
  ),
  NormalModel(
    title: '横向滑动阈值',
    getSubtitle: () => '当前:「${Pref.touchSlopH}」，系统默认值: $deviceTouchSlop',
    onTap: _showTouchSlopDialog,
    leading: const Icon(Icons.pan_tool_alt_outlined),
  ),
  NormalModel(
    title: '刷新指示器高度',
    leading: const Icon(Icons.height),
    getSubtitle: () =>
        '当前指示器高度: ${Pref.refreshDisplacement}, 刷新滑动距离: $refreshDragExtent',
    onTap: _showRefreshDialog,
  ),
  const SwitchModel(
    title: '首页切换页面动画',
    leading: Icon(Icons.home_outlined),
    setKey: SettingBoxKey.mainTabBarView,
    defaultVal: false,
    needReboot: true,
  ),
  SwitchModel(
    title: '展示头像/评论/动态装饰',
    leading: const Icon(MdiIcons.stickerCircleOutline),
    setKey: SettingBoxKey.showDecorate,
    defaultVal: true,
    onChanged: (value) => PendantAvatar.showDecorate = value,
  ),
  SwitchModel(
    title: '点击表情显示 Tooltip',
    leading: const Icon(Icons.emoji_emotions_outlined),
    setKey: SettingBoxKey.enableEmoteTooltip,
    defaultVal: false,
    onChanged: (value) => enableEmoteTooltip = value,
  ),
  SwitchModel(
    title: '显示粉丝勋章',
    leading: const Icon(MdiIcons.medalOutline),
    setKey: SettingBoxKey.showMedal,
    defaultVal: true,
    onChanged: (value) => GlobalData().showMedal = value,
  ),
  SwitchModel(
    title: '预览 Live Photo',
    subtitle: '开启则以视频形式预览 Live Photo，否则预览静态图片',
    leading: const Icon(Icons.image_outlined),
    setKey: SettingBoxKey.enableLivePhoto,
    defaultVal: true,
    onChanged: (value) => ImageModel.enableLivePhoto = value,
  ),
  SwitchModel(
    title: '侧滑关闭二级页面',
    leading: const Icon(CustomIcons.touch_app_rotate_270),
    setKey: SettingBoxKey.slideDismissReplyPage,
    defaultVal: false,
    onChanged: (value) => CommonSlideMixin.slideDismissReplyPage = value,
  ),
  SwitchModel(
    title: '静默下载图片',
    subtitle: '不显示下载 Loading 弹窗',
    leading: const Icon(Icons.download_for_offline_outlined),
    setKey: SettingBoxKey.silentDownImg,
    defaultVal: false,
    onChanged: (value) => ImageUtils.silentDownImg = value,
  ),
  SwitchModel(
    title: '长按/右键显示图片菜单',
    leading: const Icon(Icons.menu),
    setKey: SettingBoxKey.enableImgMenu,
    defaultVal: false,
    onChanged: (value) => ImageGridView.enableImgMenu = value,
  ),
  SwitchModel(
    setKey: SettingBoxKey.feedBackEnable,
    onChanged: (value) {
      enableFeedback = value;
      feedBack();
    },
    leading: const Icon(Icons.vibration_outlined),
    title: '震动反馈',
    subtitle: '请确定手机设置中已开启震动反馈',
  ),
];

void _showTouchSlopDialog(BuildContext context, VoidCallback setState) {
  String initialValue = Pref.touchSlopH.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('横向滑动阈值'),
      content: TextFormField(
        autofocus: true,
        initialValue: initialValue,
        keyboardType: const .numberWithOptions(decimal: true),
        onChanged: (value) => initialValue = value,
        inputFormatters: FilteringText.decimal,
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              final val = double.parse(initialValue);
              Get.back();
              touchSlopH = val;
              await GStorage.setting.put(SettingBoxKey.touchSlopH, val);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<void> _showRefreshDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('刷新指示器高度'),
      min: 10.0,
      max: 100.0,
      divisions: 9,
      value: Pref.refreshDisplacement,
    ),
  );
  if (res != null) {
    displacement = res;
    await GStorage.setting.put(SettingBoxKey.refreshDisplacement, res);
    if (WidgetsBinding.instance.rootElement case final context?) {
      context.visitChildElements(_visitor);
    }
    setState();
  }
}

void _visitor(Element context) {
  if (!context.mounted) return;
  if (context.widget is RefreshIndicator) {
    context.markNeedsBuild();
  } else {
    context.visitChildren(_visitor);
  }
}
