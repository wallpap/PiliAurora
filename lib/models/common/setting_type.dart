import 'package:pili_aurora/pages/setting/models/about_settings.dart';
import 'package:pili_aurora/pages/setting/models/content_settings.dart';
import 'package:pili_aurora/pages/setting/models/system_settings.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/models/play_settings.dart';
import 'package:pili_aurora/pages/setting/models/privacy_settings.dart';
import 'package:pili_aurora/pages/setting/models/recommend_settings.dart';
import 'package:pili_aurora/pages/setting/models/style_settings.dart';
import 'package:pili_aurora/pages/setting/models/video_settings.dart';

enum SettingType {
  privacySetting('账号与隐私'),
  recommendSetting('推荐与过滤'),
  videoSetting('音视频设置'),
  playSetting('播放器设置'),
  styleSetting('外观设置'),
  extraSetting('网络与存储'),
  contentSetting('内容与互动'),
  webdavSetting('备份与同步'),
  diagnosticSetting('日志与诊断'),
  about('关于'),
  ;

  final String title;
  const SettingType(this.title);

  List<SettingsModel> get settings => switch (this) {
    .privacySetting => privacySettings,
    .recommendSetting => recommendSettings,
    .videoSetting => videoSettings,
    .playSetting => playSettings,
    .styleSetting => styleSettings,
    .extraSetting => systemSettings,
    .contentSetting => contentSettings,
    .diagnosticSetting => diagnosticSettings,
    .about => aboutSettings,
    _ => throw UnimplementedError(),
  };
}
