import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/update.dart';

List<SettingsModel> get aboutSettings => [
  SwitchModel(
    title: '检查更新',
    subtitle: '每次启动时检查是否需要更新',
    leading: const Icon(Icons.system_update_alt),
    setKey: SettingBoxKey.autoUpdate,
    defaultVal: true,
    onChanged: (val) {
      if (val) {
        Update.checkUpdate(false);
      }
    },
  ),
];
