import 'dart:io' show Platform;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/models/common/sponsor_block/skip_type.dart';
import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/models/common/video/subtitle_pref_type.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/pages/fullscreen_sc_size.dart';
import 'package:pili_aurora/pages/setting/slide_color_picker.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/slider_dialog.dart';
import 'package:pili_aurora/plugin/pl_player/models/bottom_progress_behavior.dart';
import 'package:pili_aurora/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

List<SettingsModel> get playSettings => [
  SettingsGroup(
    title: '播放行为',
    subtitle: '自动播放、倍速、音量与后台播放',
    leading: const Icon(Icons.play_circle_outline),
    children: [
      ...playEnhancementSettings,
      if (PlatformUtils.isMobile)
        NormalModel(
          title: '播放器音量',
          leading: const Icon(Icons.volume_up),
          getSubtitle: () => '当前:「${Pref.playerVolume.toStringAsFixed(0)}%」',
          onTap: showPlayerVolumeDialog,
        ),
      NormalModel(
        onTap: (context, setState) => Get.toNamed('/playSpeedSet'),
        leading: const Icon(Icons.speed_outlined),
        title: '倍速设置',
        subtitle: '设置视频播放速度',
      ),
      const SwitchModel(
        title: '自动播放',
        subtitle: '进入详情页自动播放',
        leading: Icon(Icons.motion_photos_auto_outlined),
        setKey: SettingBoxKey.autoPlayEnable,
        defaultVal: false,
      ),
      if (PlatformUtils.isDesktop)
        SwitchModel(
          title: '最小化时暂停/还原时播放',
          leading: const Icon(Icons.pause_circle_outline),
          setKey: SettingBoxKey.pauseOnMinimize,
          defaultVal: false,
          onChanged: (value) {
            PlPlayerController.instance?.pauseOnMinimize.value = value;
            try {
              Get.find<MainController>().pauseOnMinimize = value;
            } catch (_) {}
          },
        ),
      if (PlatformUtils.isMobile)
        SwitchModel(
          title: '后台播放',
          subtitle: '进入后台时继续播放',
          leading: const Icon(Icons.motion_photos_pause_outlined),
          setKey: SettingBoxKey.continuePlayInBackground,
          defaultVal: false,
          onChanged: (value) =>
              PlPlayerController.instance?.continuePlayInBackground.value =
                  value,
        ),
      if (Platform.isAndroid) ...[
        SwitchModel(
          title: '后台画中画',
          subtitle: '进入后台时以小窗形式（PiP）播放',
          leading: const Icon(Icons.picture_in_picture_outlined),
          setKey: SettingBoxKey.autoPiP,
          defaultVal: false,
          onChanged: (val) {
            PlPlayerController.instance?.setAutoPiP(val);
            if (val && !videoPlayerServiceHandler!.enableBackgroundPlay) {
              SmartDialog.showToast('建议开启后台音频服务');
            }
          },
        ),
        const SwitchModel(
          title: '画中画不加载弹幕',
          subtitle: '当弹幕开关开启时，小窗屏蔽弹幕以获得较好的体验',
          leading: Icon(CustomIcons.dm_off),
          setKey: SettingBoxKey.pipNoDanmaku,
          defaultVal: false,
        ),
      ],
      if (PlatformUtils.isMobile)
        SwitchModel(
          title: '后台音频服务',
          subtitle: '避免画中画没有播放暂停功能',
          leading: const Icon(Icons.volume_up_outlined),
          setKey: SettingBoxKey.enableBackgroundPlay,
          defaultVal: true,
          onChanged: (value) =>
              videoPlayerServiceHandler!.enableBackgroundPlay = value,
        ),
      PopupModel(
        title: '播放顺序',
        leading: const Icon(Icons.repeat),
        value: () => Pref.playRepeat,
        items: PlayRepeat.values,
        onSelected: (value, setState) => GStorage.video
            .put(VideoBoxKey.playRepeat, value.index)
            .whenComplete(setState),
      ),
      const SwitchModel(
        title: '不保存播放器内的临时调整',
        subtitle: '播放顺序、画中画、后台播放等调整不写入默认偏好，当前播放器会话继续沿用；弹幕和字幕设置仍会保存',
        leading: Icon(Icons.video_settings_outlined),
        setKey: SettingBoxKey.tempPlayerConf,
        defaultVal: false,
      ),
    ],
  ),
  SettingsGroup(
    title: '手势与键盘',
    subtitle: '双击、滑动、亮度和快捷键',
    leading: const Icon(Icons.touch_app_outlined),
    children: [
      ...playGestureExtraSettings,
      if (Platform.isAndroid)
        NormalModel(
          onTap: _showAngleDegreesDialog,
          leading: const Icon(MdiIcons.angleAcute),
          title: '倾斜角度阈值',
          getSubtitle: () => '当前:「${Pref.angleDegrees}°」',
        ),
      const SwitchModel(
        title: '双击快退/快进',
        subtitle: '左侧双击快退/右侧双击快进，关闭则双击均为暂停/播放',
        leading: Icon(Icons.touch_app_outlined),
        setKey: SettingBoxKey.enableQuickDouble,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '左右侧滑动调节亮度/音量',
        leading: Icon(MdiIcons.tuneVerticalVariant),
        setKey: SettingBoxKey.enableSlideVolumeBrightness,
        defaultVal: true,
      ),
      if (Platform.isAndroid)
        const SwitchModel(
          title: '调节系统亮度',
          leading: Icon(Icons.brightness_6_outlined),
          setKey: SettingBoxKey.setSystemBrightness,
          defaultVal: false,
        ),
      const SwitchModel(
        title: '中间滑动进入/退出全屏',
        leading: Icon(MdiIcons.panVertical),
        setKey: SettingBoxKey.enableSlideFS,
        defaultVal: true,
      ),
      getVideoFilterSelectModel(
        title: '双击快进/快退时长',
        suffix: 's',
        key: SettingBoxKey.fastForBackwardDuration,
        values: [5, 10, 15],
        defaultValue: 10,
        isFilter: false,
      ),
      const SwitchModel(
        title: '滑动快进/快退使用相对时长',
        leading: Icon(Icons.swap_horiz_outlined),
        setKey: SettingBoxKey.useRelativeSlide,
        defaultVal: false,
      ),
      getVideoFilterSelectModel(
        title: '滑动快进/快退时长',
        subtitle: '从播放器一端滑到另一端的快进/快退时长',
        suffix: Pref.useRelativeSlide ? '%' : 's',
        key: SettingBoxKey.sliderDuration,
        values: [25, 50, 90, 100],
        defaultValue: 90,
        isFilter: false,
      ),
      const SwitchModel(
        title: '启用键盘控制',
        leading: Icon(Icons.keyboard_alt_outlined),
        setKey: SettingBoxKey.keyboardControl,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '全屏手势反向',
        subtitle: '默认播放器中部向上滑动进入全屏，向下退出\n开启后向下全屏，向上退出',
        leading: Icon(Icons.swap_vert),
        setKey: SettingBoxKey.fullScreenGestureReverse,
        defaultVal: false,
      ),
    ],
  ),
  SettingsGroup(
    title: '全屏与控件',
    subtitle: '全屏方向、按钮与播放进度',
    leading: const Icon(Icons.fullscreen),
    children: [
      ...playProgressExtraSettings,
      const SwitchModel(
        title: '全屏显示锁定按钮',
        leading: Icon(Icons.lock_outline),
        setKey: SettingBoxKey.showFsLockBtn,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '全屏显示截图按钮',
        leading: Icon(Icons.photo_camera_outlined),
        setKey: SettingBoxKey.showFsScreenshotBtn,
        defaultVal: true,
      ),
      SwitchModel(
        title: '全屏显示电池电量',
        leading: const Icon(Icons.battery_3_bar),
        setKey: SettingBoxKey.showBatteryLevel,
        defaultVal: PlatformUtils.isMobile,
      ),
      const SwitchModel(
        title: '竖屏扩大展示',
        subtitle: '小屏竖屏视频宽高比由16:9扩大至1:1（不支持收起）；横屏适配时，扩大至9:16',
        leading: Icon(Icons.expand_outlined),
        setKey: SettingBoxKey.enableVerticalExpand,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '自动全屏',
        subtitle: '视频开始播放时进入全屏',
        leading: Icon(Icons.fullscreen_outlined),
        setKey: SettingBoxKey.enableAutoEnter,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '自动退出全屏',
        subtitle: '视频结束播放时退出全屏',
        leading: Icon(Icons.fullscreen_exit_outlined),
        setKey: SettingBoxKey.enableAutoExit,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '延长播放控件显示时间',
        subtitle: '开启后延长至30秒，便于屏幕阅读器滑动切换控件焦点',
        leading: Icon(Icons.timer_outlined),
        setKey: SettingBoxKey.enableLongShowControl,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '全屏展示点赞/投币/收藏等操作按钮',
        leading: Icon(MdiIcons.dotsHorizontalCircleOutline),
        setKey: SettingBoxKey.showFSActionItem,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '观看人数',
        subtitle: '展示同时在看人数',
        leading: Icon(Icons.people_outlined),
        setKey: SettingBoxKey.enableOnlineTotal,
        defaultVal: false,
      ),
      NormalModel(
        title: '默认全屏方向',
        leading: const Icon(Icons.open_with_outlined),
        getSubtitle: () => '当前全屏方向：${Pref.fullScreenMode.desc}',
        onTap: _showFullScreenModeDialog,
      ),
      PopupModel(
        title: '底部进度条展示',
        leading: const Icon(Icons.border_bottom_outlined),
        value: () => Pref.btmProgressBehavior,
        items: BtmProgressBehavior.values,
        onSelected: (value, setState) => GStorage.setting
            .put(SettingBoxKey.btmProgressBehavior, value.index)
            .whenComplete(setState),
      ),
    ],
  ),
  SettingsGroup(
    title: '弹幕与字幕',
    subtitle: '弹幕交互、字幕偏好与醒目留言',
    leading: const Icon(Icons.subtitles_outlined),
    children: [
      ...danmakuExtraSettings,
      SwitchModel(
        title: '弹幕开关',
        subtitle: '是否展示弹幕',
        leading: const Icon(CustomIcons.dm_settings),
        setKey: SettingBoxKey.enableShowDanmaku,
        defaultVal: true,
        onChanged: (value) =>
            PlPlayerController.instance?.enableShowDanmaku.value = value,
      ),
      if (PlatformUtils.isMobile)
        const SwitchModel(
          title: '启用点击弹幕',
          subtitle: '点击弹幕悬停，支持点赞、复制、举报操作',
          leading: Icon(Icons.touch_app_outlined),
          setKey: SettingBoxKey.enableTapDm,
          defaultVal: true,
        ),
      NormalModel(
        title: '自动启用字幕',
        leading: const Icon(Icons.closed_caption_outlined),
        getSubtitle: () => '当前选择偏好：${Pref.subtitlePreferenceV2.desc}',
        onTap: _showSubtitleDialog,
      ),
      const SwitchModel(
        title: '分 P 继承字幕状态',
        subtitle: '切换同一视频的分 P 时，沿用当前字幕开关状态',
        leading: Icon(Icons.closed_caption_outlined),
        setKey: SettingBoxKey.inheritSubtitleState,
      ),
      PopupModel(
        title: 'SuperChat (醒目留言) 显示类型',
        leading: const Icon(Icons.live_tv),
        value: () => Pref.superChatType,
        items: SuperChatType.values,
        onSelected: (value, setState) => GStorage.setting
            .put(SettingBoxKey.superChatType, value.index)
            .whenComplete(setState),
      ),
      NormalModel(
        title: '全屏 SC 大小',
        subtitle: 'SuperChat (醒目留言) 大小设置',
        leading: const Icon(Icons.open_in_full),
        onTap: (_, _) => Get.to(const FullScreenScSize()),
      ),
    ],
  ),
];

Future<void> _showSubtitleDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<SubtitlePrefType>(
    context: context,
    builder: (context) => SelectDialog<SubtitlePrefType>(
      title: '字幕选择偏好',
      value: Pref.subtitlePreferenceV2,
      values: SubtitlePrefType.values.map((e) => (e, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.subtitlePreferenceV2,
      res.index,
    );
    setState();
  }
}

Future<void> _showFullScreenModeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<FullScreenMode>(
    context: context,
    builder: (context) => SelectDialog<FullScreenMode>(
      title: '默认全屏方向',
      value: Pref.fullScreenMode,
      values: FullScreenMode.values.map((e) => (e, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.fullScreenMode, res.index);
    setState();
  }
}

Future<void> _showAngleDegreesDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('倾斜角度阈值'),
      min: 10.0,
      max: 90.0,
      divisions: 90,
      precise: 0,
      value: Pref.angleDegrees.toDouble(),
      suffix: '°',
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.angleDegrees, res.toInt());
    setState();
  }
}

Future<void> showPlayerVolumeDialog(
  BuildContext context,
  VoidCallback setState, {
  ValueChanged<double>? onChanged,
  double? value,
}) {
  return showVolumeDialog(
    context,
    title: const Text('播放器音量'),
    value: value ?? Pref.playerVolume,
    onChanging: onChanged,
    onChanged: (value) => GStorage.setting
        .put(SettingBoxKey.playerVolume, value.roundToDouble())
        .whenComplete(setState),
  );
}

Future<void> showVolumeDialog(
  BuildContext context, {
  required Widget title,
  required double value,
  required ValueChanged<double> onChanged,
  ValueChanged<double>? onChanging,
}) async {
  var previewed = false;
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: title,
      min: 0,
      max: 100,
      divisions: 100,
      precise: 0,
      value: value,
      suffix: '%',
      onChanged: (nextValue) {
        previewed = true;
        onChanging?.call(nextValue);
      },
    ),
  );
  if (res != null) {
    onChanged(res);
  } else if (previewed) {
    onChanging?.call(value);
  }
}

List<SettingsModel> get playEnhancementSettings => [
  SplitModel(
    normalModel: const NormalModel.split(
      title: '空降助手',
      subtitle: '点击配置',
      leading: Icon(CustomIcons.shield_play_arrow),
    ),
    switchModel: SwitchModel.split(
      defaultVal: false,
      setKey: SettingBoxKey.enableSponsorBlock,
      onTap: (context) => Get.toNamed('/sponsorBlock'),
    ),
  ),
  PopupModel<SkipType>(
    title: '番剧片头/片尾跳过类型',
    leading: const Icon(MdiIcons.debugStepOver),
    value: () => Pref.pgcSkipType,
    items: SkipType.values,
    onSelected: (value, setState) => GStorage.setting
        .put(SettingBoxKey.pgcSkipType, value.index)
        .whenComplete(setState),
  ),
  const SwitchModel(
    title: '分P/合集：倒序播放从首集开始播放',
    subtitle: '开启则自动切换为倒序首集，否则保持当前集',
    leading: Icon(MdiIcons.sort),
    setKey: SettingBoxKey.reverseFromFirst,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '显示继续播放分P提示',
    leading: Icon(Icons.local_parking),
    setKey: SettingBoxKey.continuePlayingPart,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '手动播放前预加载视频',
    subtitle: '关闭自动播放时，提前加载并暂停在续播位置，减少点击播放后的等待；会消耗流量和播放器资源',
    leading: Icon(Icons.play_circle_outlined),
    setKey: SettingBoxKey.preInitPlayer,
    defaultVal: false,
  ),
];

NormalModel get danmakuFrameRateSetting => NormalModel(
  title: '弹幕帧率（实验性）',
  leading: const Icon(Icons.speed_outlined),
  getSubtitle: () =>
      '${Pref.danmakuFrameRate == 0 ? '跟随屏幕' : '目标 ${Pref.danmakuFrameRate} FPS'}；立即生效',
  onTap: _showDanmakuFrameRateDialog,
);

List<SettingsModel> get danmakuExtraSettings => [
  if (!Platform.isWindows) danmakuFrameRateSetting,
  NormalModel(
    title: '弹幕轨道间距',
    subtitle: '1–3 倍，默认 1.6；数值越小，同屏轨道越多',
    leading: const Icon(CustomIcons.dm_settings),
    getTrailing: (theme) => Text(
      Pref.danmakuLineHeight.toString(),
      style: theme.textTheme.titleSmall,
    ),
    onTap: _showDmHeightDialog,
  ),
  const SwitchModel(
    title: '显示会员彩色弹幕',
    leading: Icon(MdiIcons.gradientHorizontal),
    setKey: SettingBoxKey.showVipDanmaku,
    defaultVal: true,
  ),
  ...danmakuMergeSettings,
];

/// 设置页与播放器弹幕面板共用合并选项及持久化逻辑。
List<SettingsModel> get danmakuMergeSettings => [
  const SwitchModel(
    title: '合并弹幕',
    subtitle: '合并20秒内相同或相似的弹幕；立即生效',
    leading: Icon(Icons.merge),
    setKey: SettingBoxKey.mergeDanmaku,
    defaultVal: false,
  ),
  const SwitchModel(
    title: '合并弹幕字号放大',
    subtitle: '按重复数量放大，最高两倍；立即生效',
    leading: Icon(Icons.format_size),
    setKey: SettingBoxKey.mergeDanmakuScale,
    defaultVal: true,
  ),
  NormalModel(
    title: '合并弹幕放大阈值',
    getSubtitle: () => '重复数量超过${Pref.mergeDanmakuThreshold}条时放大；立即生效',
    leading: const Icon(Icons.filter_7_outlined),
    onTap: (context, setState) =>
        _showMergeScaleDialog(context, setState, threshold: true),
  ),
  NormalModel(
    title: '合并弹幕放大速度',
    getSubtitle: () =>
        '对数底数 ${Pref.mergeDanmakuLogBase.toStringAsFixed(1)}，越小放大越快；立即生效',
    leading: const Icon(Icons.speed),
    onTap: (context, setState) =>
        _showMergeScaleDialog(context, setState, threshold: false),
  ),
];

List<SettingsModel> get playGestureExtraSettings => [
  const SwitchModel(
    title: '启用双指缩小视频',
    leading: Icon(Icons.pinch),
    setKey: SettingBoxKey.enableShrinkVideoSize,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '启用拖拽字幕调整底部边距',
    leading: Icon(MdiIcons.dragVariant),
    setKey: SettingBoxKey.enableDragSubtitle,
    defaultVal: false,
  ),
];

Future<void> _showMergeScaleDialog(
  BuildContext context,
  VoidCallback setState, {
  required bool threshold,
}) async {
  final value = await showDialog<double>(
    context: context,
    builder: (_) => SliderDialog(
      title: Text(threshold ? '合并弹幕放大阈值' : '合并弹幕放大速度（越小越快）'),
      value: threshold
          ? Pref.mergeDanmakuThreshold.toDouble()
          : Pref.mergeDanmakuLogBase,
      min: 2,
      max: threshold ? 50 : 20,
      divisions: threshold ? 48 : 36,
      precise: threshold ? 0 : 1,
    ),
  );
  if (value == null) return;
  await GStorage.setting.put(
    threshold
        ? SettingBoxKey.mergeDanmakuThreshold
        : SettingBoxKey.mergeDanmakuLogBase,
    threshold ? value.round() : value,
  );
  if (context.mounted) setState();
}

List<SettingsModel> get playProgressExtraSettings => [
  const SwitchModel(
    title: '滑动跳转预览视频缩略图',
    leading: Icon(Icons.preview_outlined),
    setKey: SettingBoxKey.showSeekPreview,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '显示高能进度条',
    subtitle: '高能进度条反应了在时域上，单位时间内弹幕发送量的变化趋势',
    leading: Icon(Icons.show_chart),
    setKey: SettingBoxKey.showDmChart,
    defaultVal: false,
  ),
  NormalModel(
    title: '高能进度条颜色',
    leading: const Icon(Icons.palette_outlined),
    getSubtitle: () {
      final color = Pref.dmChartColor;
      return color == null
          ? '跟随主题'
          : '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';
    },
    getTrailing: (theme) => Icon(
      Icons.circle,
      color: Pref.dmChartColor ?? theme.colorScheme.primary,
      size: 20,
    ),
    onTap: _showDmChartColorDialog,
  ),
];

void _showDmChartColorDialog(BuildContext context, VoidCallback setState) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      clipBehavior: Clip.hardEdge,
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      title: const Text('高能进度条颜色'),
      content: SlideColorPicker(
        color: Pref.dmChartColor ?? const Color(0xFFFB7299),
        showResetBtn: true,
        onChanged: (color) async {
          if (color == null) {
            await GStorage.setting.delete(SettingBoxKey.dmChartColor);
          } else {
            await GStorage.setting.put(
              SettingBoxKey.dmChartColor,
              color.toARGB32(),
            );
          }
          setState();
        },
      ),
    ),
  );
}

Future<void> _showDanmakuFrameRateDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final result = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '弹幕帧率（实验性）',
      value: Pref.danmakuFrameRate,
      values: const [
        (0, '跟随屏幕'),
        (30, '30 FPS'),
        (60, '60 FPS'),
        (90, '90 FPS'),
        (120, '120 FPS'),
      ],
      subtitleBuilder: (_, index) => Text(
        index == 0 ? '沿用屏幕刷新节奏；立即生效' : '目标弹幕帧率；屏幕刷新率受视频时序与设备档位影响，可能更高；立即生效',
      ),
    ),
  );
  if (result == null || result == Pref.danmakuFrameRate) return;
  await GStorage.setting.put(SettingBoxKey.danmakuFrameRate, result);
  if (context.mounted) setState();
}

Future<void> _showDmHeightDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final result = await showDialog<double>(
    context: context,
    builder: (_) => SliderDialog(
      title: const Text('弹幕轨道间距'),
      value: Pref.danmakuLineHeight,
      min: 1,
      max: 3,
      divisions: 20,
      suffix: ' 倍',
    ),
  );
  if (result == null) return;
  await GStorage.setting.put(SettingBoxKey.danmakuLineHeight, result);
  DanmakuOptions.danmakuLineHeight = result;
  if (context.mounted) setState();
}
