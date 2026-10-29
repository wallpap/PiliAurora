import 'dart:io';

import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/audio_normalization.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/common/video/live_quality.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/decoder_test_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/ordered_multi_select_dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/plugin/pl_player/models/audio_output_type.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/filtering_text.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/video_utils.dart';

List<SettingsModel> get videoSettings => [
  SettingsGroup(
    title: '画质与音质',
    subtitle: '默认与蜂窝网络偏好',
    leading: const Icon(Icons.high_quality),
    children: [
      const SwitchModel(
        title: '免登录1080P',
        subtitle: '免登录查看1080P视频',
        leading: Icon(Icons.hd_outlined),
        setKey: SettingBoxKey.p1080,
        defaultVal: true,
      ),
      NormalModel(
        title: '默认画质',
        leading: const Icon(Icons.video_settings_outlined),
        getSubtitle: () =>
            '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQa).desc}',
        onTap: _showVideoQaDialog,
      ),
      NormalModel(
        title: '蜂窝网络画质',
        leading: const Icon(Icons.video_settings_outlined),
        getSubtitle: () =>
            '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQaCellular).desc}',
        onTap: _showVideoCellularQaDialog,
      ),
      NormalModel(
        title: '默认音质',
        leading: const Icon(Icons.music_video_outlined),
        getSubtitle: () =>
            '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQa).desc}',
        onTap: _showAudioQaDialog,
      ),
      NormalModel(
        title: '蜂窝网络音质',
        leading: const Icon(Icons.music_video_outlined),
        getSubtitle: () =>
            '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQaCellular).desc}',
        onTap: _showAudioCellularQaDialog,
      ),
      NormalModel(
        title: '直播默认画质',
        leading: const Icon(Icons.video_settings_outlined),
        getSubtitle: () =>
            '当前画质：${LiveQuality.fromCode(Pref.liveQuality)?.desc}',
        onTap: _showLiveQaDialog,
      ),
      NormalModel(
        title: '蜂窝网络直播默认画质',
        leading: const Icon(Icons.video_settings_outlined),
        getSubtitle: () =>
            '当前画质：${LiveQuality.fromCode(Pref.liveQualityCellular)?.desc}',
        onTap: _showLiveCellularQaDialog,
      ),
    ],
  ),
  SettingsGroup(
    title: '播放线路',
    subtitle: 'CDN、回退与定向流量',
    leading: const Icon(Icons.alt_route),
    children: [
      NormalModel(
        title: 'B站定向流量支持',
        subtitle: '若套餐含B站定向流量，则会自动使用。可查阅运营商的流量记录确认。',
        leading: const Icon(Icons.perm_data_setting_outlined),
        getTrailing: (theme) => IgnorePointer(
          child: Transform.scale(
            scale: 0.8,
            alignment: Alignment.centerRight,
            child: Switch(
              value: true,
              onChanged: (_) {},
              thumbIcon: WidgetStateProperty.all(
                const Icon(Icons.lock_outline_rounded),
              ),
            ),
          ),
        ),
      ),
      NormalModel(
        title: 'CDN 设置',
        leading: const Icon(MdiIcons.cloudPlusOutline),
        getSubtitle: () =>
            '当前使用：${VideoUtils.cdnService.desc}，部分 CDN 可能失效，如无法播放请尝试切换',
        onTap: _showCDNDialog,
      ),
      SwitchModel(
        title: '多 CDN 自动回退（实验性功能）',
        subtitle: '连接失败时尝试备用 CDN，重新打开视频后生效',
        leading: const Icon(Icons.cloud_sync_outlined),
        setKey: SettingBoxKey.enableMultiCdn,
        defaultVal: false,
        children: [
          NormalModel(
            title: 'CDN 回退顺序',
            leading: const Icon(Icons.format_list_numbered),
            getSubtitle: () {
              final order = Pref.cdnFallbackOrder;
              return order.isEmpty
                  ? '默认按 CDN 列表顺序；首选 CDN 优先'
                  : '首选 CDN 优先，失败后按 ${order.map((e) => e.desc).join(' → ')} 回退';
            },
            onTap: _showCdnFallbackOrderDialog,
          ),
        ],
      ),
      NormalModel(
        title: '直播 CDN 设置',
        leading: const Icon(MdiIcons.cloudPlusOutline),
        getSubtitle: () => '当前使用：${Pref.liveCdnUrl ?? "默认"}',
        onTap: _showLiveCDNDialog,
      ),
      const SwitchModel(
        title: 'CDN 测速',
        leading: Icon(Icons.speed),
        subtitle: '测速通过模拟加载视频实现，注意流量消耗，结果仅供参考',
        setKey: SettingBoxKey.cdnSpeedTest,
        defaultVal: true,
      ),
      SwitchModel(
        title: '音频不跟随 CDN 设置',
        subtitle: '直接采用备用 URL，可解决部分视频无声',
        leading: const Icon(MdiIcons.musicNotePlus),
        setKey: SettingBoxKey.disableAudioCDN,
        defaultVal: false,
        onChanged: (value) => VideoUtils.disableAudioCDN = value,
      ),
    ],
  ),
  SettingsGroup(
    title: '解码与输出',
    subtitle: '编码格式、硬件解码、缓冲、同步与音频设备',
    leading: const Icon(Icons.video_settings_outlined),
    children: [
      NormalModel(
        title: '首选解码格式',
        leading: const Icon(Icons.movie_creation_outlined),
        getSubtitle: () =>
            '首选解码格式：${(Pref.preferCodecs.map((i) => i.name).join(","))}，请根据设备支持情况与需求调整',
        onTap: _showCodecsDialog,
      ),
      NormalModel(
        title: '蜂窝网络首选解码格式',
        leading: const Icon(Icons.movie_creation_outlined),
        getSubtitle: () =>
            '首选解码格式：${(Pref.preferCodecsCellular.map((i) => i.name).join(","))}，请根据设备支持情况与需求调整',
        onTap: _showCellularCodecsDialog,
      ),
      ...videoEnhancementSettings,
      const SwitchModel(
        title: '开启硬解',
        subtitle: '以较低功耗播放视频，若异常卡死请关闭',
        leading: Icon(Icons.flash_on_outlined),
        setKey: SettingBoxKey.enableHA,
        defaultVal: true,
      ),
      if (Platform.isAndroid)
        const SwitchModel(
          title: '自动纹理缩放（实验性功能）',
          subtitle: '按屏幕分辨率等比缩小视频输出，减少纹理开销。关闭时使用原生尺寸处理，下次加载视频生效',
          leading: Icon(Icons.aspect_ratio_outlined),
          setKey: SettingBoxKey.enableAndroidTextureScaling,
          defaultVal: false,
        ),
      if (Platform.isAndroid)
        NormalModel(
          title: '音频输出后端',
          leading: const Icon(Icons.speaker_outlined),
          getSubtitle: () => '当前：${Pref.audioOutput}；重新打开播放器后生效',
          onTap: _showAudioOutputDialog,
        ),
      NormalModel(
        title: '缓冲大小',
        leading: const Icon(Icons.storage_outlined),
        getSubtitle: () =>
            '点播前向、后向各 ${Pref.bufferSize} MiB，直播前向 ${Pref.bufferSize * 2} MiB；分离音视频分别受此上限约束，下次加载生效',
        onTap: _showBufferSizeDialog,
      ),
      NormalModel(
        title: '缓冲时长',
        leading: const Icon(Icons.av_timer),
        getSubtitle: () =>
            '目标 ${Pref.bufferSec} 秒实际播放时间，倍速时换算为媒体时长；同时受缓冲大小限制。直播使用独立策略，下次加载生效',
        onTap: _showBufferSecDialog,
      ),
      NormalModel(
        title: '音频时钟平滑',
        leading: const Icon(Icons.sync_rounded),
        getSubtitle: () => '当前：${Pref.autosync}；平滑音频设备时序测量，0 为关闭；下次加载生效',
        onTap: _showAutoSyncDialog,
      ),
      NormalModel(
        title: '视频同步',
        leading: const Icon(Icons.view_timeline_outlined),
        getSubtitle: () =>
            '当前：${_videoSyncName(Pref.videoSync)}；控制音画与屏幕刷新率的协调，下次加载生效',
        onTap: _showVideoSyncDialog,
      ),
      NormalModel(
        title: '硬解模式',
        leading: const Icon(Icons.memory_outlined),
        getSubtitle: () =>
            '当前：${Pref.hardwareDecoding.split(',').map(_hwdecName).join(' → ')}，按顺序尝试',
        onTap: _showHwDecDialog,
      ),
      const NormalModel(
        title: '解码器测试',
        subtitle: '选择视频格式和硬解模式，比较播放兼容性与 CPU、内存、GPU 占用',
        leading: Icon(Icons.speed_outlined),
        onTap: _showDecoderTestDialog,
      ),
    ],
  ),
];

String _videoSyncName(String value) => switch (value) {
  'audio' => '跟随声音时钟',
  'display-resample' => '匹配屏幕刷新率（推荐）',
  'display-resample-vdrop' => '匹配刷新率，必要时少显示一帧',
  'display-resample-desync' => '匹配刷新率，允许音画短暂偏差',
  'display-tempo' => '微调播放速度以匹配屏幕',
  'display-vdrop' => '匹配刷新率，必要时跳过画面',
  'display-adrop' => '匹配刷新率，必要时调整声音',
  'display-desync' => '跟随屏幕刷新率，不强制音画同步',
  'desync' => '不做音画同步',
  _ => value,
};

String _hwdecName(String value) =>
    HwDecType.values
        .where((type) => type.hwdec == value)
        .map((type) => type.desc.split('：').first)
        .firstOrNull ??
    value;

Future<void> _showDecoderTestDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => const DecoderTestDialog(),
  );
}

Future<void> _showCDNDialog(BuildContext context, VoidCallback setState) async {
  final res = await showDialog<CDNService>(
    context: context,
    builder: (context) => const CdnSelectDialog(),
  );
  if (res != null) {
    VideoUtils.cdnService = res;
    await GStorage.setting.put(SettingBoxKey.CDNService, res.name);
    setState();
  }
}

Future<void> _showCdnFallbackOrderDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final result = await showDialog<List<CDNService>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<CDNService>(
      title: 'CDN 回退顺序（按点击顺序，留空使用列表顺序）',
      initValues: Pref.cdnFallbackOrder,
      values: {for (final service in CDNService.values) service: service.desc},
    ),
  );
  if (result != null) {
    await GStorage.setting.put(
      SettingBoxKey.cdnFallbackOrder,
      result.map((service) => service.name).toList(),
    );
    setState();
  }
}

Future<void> _showLiveCDNDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  String host = Pref.liveCdnUrl ?? '';
  String? res = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入CDN host'),
      content: TextFormField(
        initialValue: host,
        autofocus: true,
        onChanged: (value) => host = value,
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
          onPressed: () => Get.back(result: host),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (res != null) {
    if (res.isEmpty) {
      res = null;
      await GStorage.setting.delete(SettingBoxKey.liveCdnUrl);
    } else {
      if (!res.startsWith('http')) {
        res = 'https://$res';
      }
      await GStorage.setting.put(SettingBoxKey.liveCdnUrl, res);
    }
    VideoUtils.liveCdnUrl = res;
    setState();
  }
}

Future<void> _showVideoQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '默认画质',
      value: Pref.defaultVideoQa,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultVideoQa, res);
    setState();
  }
}

Future<void> _showVideoCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络画质',
      value: Pref.defaultVideoQaCellular,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultVideoQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showAudioQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '默认音质',
      value: Pref.defaultAudioQa,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultAudioQa, res);
    setState();
  }
}

Future<void> _showAudioCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络音质',
      value: Pref.defaultAudioQaCellular,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultAudioQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showLiveQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '直播默认画质',
      value: Pref.liveQuality,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQuality, res);
    setState();
  }
}

Future<void> _showLiveCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络直播默认画质',
      value: Pref.liveQualityCellular,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQualityCellular, res);
    setState();
  }
}

Future<void> _showCodecsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<VideoDecodeFormatType>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<VideoDecodeFormatType>(
      title: '首选解码格式',
      initValues: Pref.preferCodecs,
      values: {for (final e in VideoDecodeFormatType.values) e: e.name},
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.preferCodecs,
      res.map((i) => i.name).toList(),
    );
    setState();
  }
}

Future<void> _showCellularCodecsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<VideoDecodeFormatType>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<VideoDecodeFormatType>(
      title: '蜂窝网络首选解码格式',
      initValues: Pref.preferCodecsCellular,
      values: {for (final e in VideoDecodeFormatType.values) e: e.name},
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.preferCodecsCellular,
      res.map((i) => i.name).toList(),
    );
    setState();
  }
}

Future<void> _showAudioOutputDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: '音频输出后端',
      initValues: Pref.audioOutput.split(','),
      values: {
        for (final e in AudioOutput.values) e.name: e.label,
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.audioOutput,
      res.join(','),
    );
    setState();
  }
}

Future<void> _showVideoSyncDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  const options = <(String, String, String)>[
    ('audio', '跟随声音时钟', '适合普通显示器，优先让画面跟上声音'),
    ('display-resample', '匹配屏幕刷新率（推荐）', '平滑调整画面节奏，减少卡顿和音画偏差'),
    ('display-resample-vdrop', '匹配刷新率，必要时跳帧', '平时平滑播放，偏差过大时跳过一帧'),
    ('display-resample-desync', '匹配刷新率，允许短暂偏差', '优先画面流畅，不强制修正音画偏差'),
    ('display-tempo', '微调播放速度', '轻微加快或放慢声音来匹配屏幕刷新率'),
    ('display-vdrop', '匹配刷新率，跳过画面', '偏差过大时跳过画面帧'),
    ('display-adrop', '匹配刷新率，调整声音', '偏差过大时微调声音节奏'),
    ('display-desync', '跟随屏幕刷新率', '优先匹配屏幕，不主动保持音画同步'),
    ('desync', '不做同步', '不校正音画与屏幕刷新率的差异'),
  ];
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '视频同步',
      value: Pref.videoSync,
      values: options.map((option) => (option.$1, option.$2)).toList(),
      subtitleBuilder: (context, index) => Text(options[index].$3),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.videoSync, res);
    setState();
  }
}

Future<void> _showHwDecDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: '硬解模式',
      initValues: Pref.hardwareDecoding.split(','),
      values: {
        for (final e in HwDecType.values) e.hwdec: '${e.desc}\n参数：${e.hwdec}',
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.hardwareDecoding,
      res.join(','),
    );
    setState();
  }
}

void _showAutoSyncDialog(BuildContext context, VoidCallback setState) {
  String autosync = Pref.autosync.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('音频时钟平滑'),
      content: TextFormField(
        autofocus: true,
        initialValue: autosync,
        keyboardType: TextInputType.number,
        onChanged: (value) => autosync = value,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
              // validate
              int.parse(autosync);
              Get.back();
              await GStorage.setting.put(SettingBoxKey.autosync, autosync);
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

void _showDecimalDialog(
  BuildContext context,
  VoidCallback setState, {
  required String key,
  required double defVal,
  required String title,
  required String? suffix,
}) {
  String value = (GStorage.setting.get(key) ?? defVal).toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        autofocus: true,
        initialValue: value,
        keyboardType: const .numberWithOptions(decimal: true),
        onChanged: (val) => value = val,
        inputFormatters: FilteringText.decimal,
        decoration: suffix == null ? null : InputDecoration(suffixText: suffix),
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
              final val = double.parse(value);
              Get.back();
              await GStorage.setting.put(key, val);
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

void _showBufferSizeDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSize,
      defVal: Pref.bufferSize,
      title: '缓冲大小',
      suffix: 'MB',
    );

void _showBufferSecDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSec,
      defVal: Pref.bufferSec,
      title: '缓冲时长',
      suffix: 's',
    );

List<SettingsModel> get videoEnhancementSettings => [
  if (Platform.isAndroid)
    NormalModel(
      title: '音量均衡',
      leading: const Icon(Icons.multitrack_audio),
      getSubtitle: () {
        final audioNormalization = AudioNormalization.getTitleFromConfig(
          Pref.audioNormalization,
        );
        String fallback = Pref.fallbackNormalization;
        if (fallback == '0') {
          fallback = '';
        } else {
          fallback =
              '，无参数时:「${AudioNormalization.getTitleFromConfig(fallback)}」';
        }
        return '当前:「$audioNormalization」$fallback';
      },
      onTap: audioNormalization,
    ),
  NormalModel(
    title: '超分辨率',
    leading: const Icon(Icons.stay_current_landscape_outlined),
    getSubtitle: () =>
        '当前:「${Pref.superResolutionType.label}」\n默认设置用于番剧，其他视频可在播放器内选择\n源视频超过当前屏幕分辨率时不启用；需要输出后端支持 GPU 着色器',
    onTap: _showSuperResolutionDialog,
  ),
];

Future<void> audioNormalization(
  BuildContext context,
  VoidCallback setState, {
  bool fallback = false,
}) async {
  final key = fallback
      ? SettingBoxKey.fallbackNormalization
      : SettingBoxKey.audioNormalization;
  final res = await showDialog<String>(
    context: context,
    builder: (context) {
      String audioNormalization = fallback
          ? Pref.fallbackNormalization
          : Pref.audioNormalization;
      Set<String> values = {
        '0',
        '1',
        if (!fallback) '2',
        audioNormalization,
        '3',
      };
      return SelectDialog<String>(
        title: fallback ? '服务器无loudnorm配置时使用' : '音量均衡',
        toggleable: true,
        value: audioNormalization,
        values: values
            .map(
              (e) => (
                e,
                switch (e) {
                  '0' => AudioNormalization.disable.title,
                  '1' => AudioNormalization.dynaudnorm.title,
                  '2' => AudioNormalization.loudnorm.title,
                  '3' => AudioNormalization.custom.title,
                  _ => e,
                },
              ),
            )
            .toList(),
      );
    },
  );
  if (res != null && context.mounted) {
    if (res == '3') {
      String param = '';
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('自定义参数'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              const Text('等同于 --lavfi-complex="[aid1] 参数 [ao]"'),
              TextField(
                autofocus: true,
                onChanged: (value) => param = value,
              ),
            ],
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
              onPressed: () {
                Get.back();
                GStorage.setting.put(key, param);
                if (!fallback &&
                    AudioNormalization.loudnormRegExp.hasMatch(param)) {
                  audioNormalization(context, setState, fallback: true);
                }
                setState();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } else {
      GStorage.setting.put(key, res);
      if (res == '2') {
        audioNormalization(context, setState, fallback: true);
      }
      setState();
    }
  }
}

Future<void> _showSuperResolutionDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<SuperResolutionType>(
    context: context,
    builder: (context) => SelectDialog<SuperResolutionType>(
      title: '超分辨率',
      value: Pref.superResolutionType,
      values: SuperResolutionType.values.map((e) => (e, e.label)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.superResolutionType,
      res.index,
    );
    setState();
  }
}
