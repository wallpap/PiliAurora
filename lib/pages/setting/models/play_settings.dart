import 'dart:io' show Platform;
import 'dart:math' show max;

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
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/slider_dialog.dart';
import 'package:pili_aurora/plugin/pl_player/models/bottom_progress_behavior.dart';
import 'package:pili_aurora/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/filtering_text.dart';
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
        )
      else
        NormalModel(
          title: '最高音量',
          leading: const Icon(Icons.volume_up),
          getSubtitle: () =>
              '当前:「${(Pref.maxVolume * 100).toStringAsFixed(0)}%」',
          onTap: _showMaxVolumeDialog,
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
            try {
              Get.find<MainController>().pauseOnMinimize = value;
            } catch (_) {}
          },
        ),
      if (PlatformUtils.isMobile)
        const SwitchModel(
          title: '后台播放',
          subtitle: '进入后台时继续播放',
          leading: Icon(Icons.motion_photos_pause_outlined),
          setKey: SettingBoxKey.continuePlayInBackground,
          defaultVal: false,
        ),
      if (Platform.isAndroid) ...[
        SwitchModel(
          title: '后台画中画',
          subtitle: '进入后台时以小窗形式（PiP）播放',
          leading: const Icon(Icons.picture_in_picture_outlined),
          setKey: SettingBoxKey.autoPiP,
          defaultVal: false,
          onChanged: (val) {
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
        title: '播放器设置仅对当前生效',
        subtitle: '弹幕、字幕及部分设置中没有的设置除外',
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
      const SwitchModel(
        title: '弹幕开关',
        subtitle: '是否展示弹幕',
        leading: Icon(CustomIcons.dm_settings),
        setKey: SettingBoxKey.enableShowDanmaku,
        defaultVal: true,
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
}) {
  return showVolumeDialog(
    context,
    title: const Text('播放器音量'),
    value: Pref.playerVolume,
    onChanged: (value) => GStorage.setting
        .put(SettingBoxKey.playerVolume, value)
        .whenComplete(() {
          setState();
          onChanged?.call(value);
        }),
  );
}

Future<void> _showMaxVolumeDialog(
  BuildContext context,
  VoidCallback setState,
) {
  return showVolumeDialog(
    context,
    title: const Text('最高音量'),
    value: Pref.maxVolume * 100,
    onChanged: (rawValue) {
      final maxVolume = (rawValue / 100).toPrecision(2);
      if (Pref.desktopVolume > maxVolume) {
        GStorage.setting.put(SettingBoxKey.desktopVolume, maxVolume);
      }
      GStorage.setting
          .put(SettingBoxKey.maxVolume, maxVolume)
          .whenComplete(setState);
    },
  );
}

const kMinVolume = 100.0;
const kMaxVolume = 300.0;

Future<void> showVolumeDialog(
  BuildContext context, {
  required Widget title,
  required double value,
  required ValueChanged<double> onChanged,
}) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: title,
      min: kMinVolume,
      max: kMaxVolume,
      divisions: 40,
      precise: 0,
      value: value,
      suffix: '%',
    ),
  );
  if (res != null) {
    onChanged(res);
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
    title: '提前初始化播放器',
    subtitle: '相对减少手动播放加载时间',
    leading: Icon(Icons.play_circle_outlined),
    setKey: SettingBoxKey.preInitPlayer,
    defaultVal: false,
  ),
];

List<SettingsModel> get danmakuExtraSettings => [
  NormalModel(
    title: '弹幕行高',
    subtitle: '默认1.6',
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
  const SwitchModel(
    title: '合并弹幕',
    subtitle: '合并一段时间内获取到的相同弹幕',
    leading: Icon(Icons.merge),
    setKey: SettingBoxKey.mergeDanmaku,
    defaultVal: false,
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
];

void _showDmHeightDialog(BuildContext context, VoidCallback setState) {
  String danmakuLineHeight = Pref.danmakuLineHeight.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('弹幕行高'),
      content: TextFormField(
        autofocus: true,
        initialValue: danmakuLineHeight,
        keyboardType: const .numberWithOptions(decimal: true),
        onChanged: (value) => danmakuLineHeight = value,
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
              final val = max(
                1.0,
                double.parse(danmakuLineHeight).toPrecision(1),
              );
              Get.back();
              await GStorage.setting.put(SettingBoxKey.danmakuLineHeight, val);
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
