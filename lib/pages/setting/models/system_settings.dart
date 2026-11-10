import 'dart:io' show Platform, Directory;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide RefreshIndicator;
import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/setting_save.dart';
import 'package:pili_aurora/pages/setting/widgets/clear_cache_item.dart';
import 'package:pili_aurora/pages/setting/widgets/doc_provider_item.dart';
import 'package:pili_aurora/pages/setting/widgets/slider_dialog.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/filtering_text.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';

List<SettingsModel> get systemSettings => [
  const SettingsGroup(
    title: '网络连接',
    subtitle: '代理、协议与连接重试',
    leading: Icon(Icons.wifi),
    children: [
      SwitchModel(
        title: '禁用 SSL 证书验证',
        subtitle: '谨慎开启，禁用容易受到中间人攻击',
        leading: Icon(Icons.security),
        needReboot: true,
        setKey: SettingBoxKey.badCertificateCallback,
      ),
      SwitchModel(
        title: '启用HTTP/2',
        leading: Icon(Icons.swap_horizontal_circle_outlined),
        setKey: SettingBoxKey.enableHttp2,
        defaultVal: false,
        needReboot: true,
      ),
      NormalModel(
        title: '连接重试次数',
        subtitle: '为0时禁用',
        leading: Icon(Icons.repeat),
        onTap: _showReplyCountDialog,
      ),
      NormalModel(
        title: '连接重试间隔',
        subtitle: '实际间隔 = 间隔 * 第x次重试',
        leading: Icon(Icons.more_time_outlined),
        onTap: _showReplyDelayDialog,
      ),
      SplitModel(
        normalModel: NormalModel.split(
          title: '设置代理',
          subtitle: '设置代理 host:port',
          leading: Icon(Icons.airplane_ticket_outlined),
        ),
        switchModel: SwitchModel.split(
          defaultVal: false,
          setKey: SettingBoxKey.enableSystemProxy,
          onTap: _showProxyDialog,
        ),
      ),
    ],
  ),
  SettingsGroup(
    title: '存储与应用',
    subtitle: '缓存、下载目录与应用行为',
    leading: const Icon(Icons.storage_outlined),
    children: [
      if (PlatformUtils.isDesktop) ...[
        SwitchModel(
          title: '退出时最小化',
          leading: const Icon(Icons.exit_to_app),
          setKey: SettingBoxKey.minimizeOnExit,
          defaultVal: true,
          onChanged: (value) {
            try {
              Get.find<MainController>().minimizeOnExit = value;
            } catch (_) {}
          },
        ),
        NormalModel(
          title: '缓存路径',
          getSubtitle: () => downloadPath,
          leading: const Icon(Icons.storage),
          onTap: _showDownPathDialog,
        ),
      ] else if (Platform.isAndroid)
        const _DocProviderModel(),
      const _ClearCacheModel(),
      NormalModel(
        title: '最大缓存大小',
        getSubtitle: () =>
            '当前最大缓存大小: 「${CacheManager.formatSize(Pref.maxCacheSize)}」',
        leading: const Icon(Icons.delete_outlined),
        onTap: _showCacheDialog,
      ),
    ],
  ),
];

class _ClearCacheModel extends NormalModel {
  const _ClearCacheModel() : super(title: '清除缓存', subtitle: '图片及网络缓存');

  @override
  Widget get widget => const ClearCacheItem();
}

class _DocProviderModel extends NormalModel {
  const _DocProviderModel()
    : super(
        title: DocProviderItem.title,
        subtitle: DocProviderItem.description,
        leading: const Icon(Icons.storage),
      );

  @override
  Widget get widget => const DocProviderItem();
}

List<SettingsModel> get diagnosticSettings => [
  NormalModel(
    title: '日志与诊断',
    subtitle: '异常、运行与播放日志，性能记录和诊断包',
    leading: const Icon(Icons.bug_report_outlined),
    getTrailing: (_) => const Icon(Icons.chevron_right),
    onTap: (context, _) => Get.toNamed('/logs'),
  ),
];

bool _changingDownloadPath = false;

Future<void> _setDownloadPath(
  BuildContext context,
  VoidCallback setState,
  String nextPath,
) async {
  if (_changingDownloadPath || nextPath == downloadPath) return;
  _changingDownloadPath = true;
  try {
    final service = Get.find<DownloadService>();
    final pause = await service.cancelDownload(
      isDelete: false,
      downloadNext: false,
    );
    if (!pause.isSuccess) {
      if (context.mounted) pause.toast();
      return;
    }
    if (!context.mounted) return;
    if (nextPath == defDownloadPath) {
      await GStorage.setting.delete(SettingBoxKey.downloadPath);
    } else {
      await GStorage.setting.put(SettingBoxKey.downloadPath, nextPath);
    }
    downloadPath = nextPath;
    if (context.mounted) setState();
    final result = await service.initDownloadList();
    if (!result.isSuccess && context.mounted) result.toast();
  } catch (error, stack) {
    logger.e('下载目录设置失败', error: error.runtimeType, stackTrace: stack);
    if (context.mounted) SmartDialog.showToast('下载目录设置失败，请重试');
  } finally {
    _changingDownloadPath = false;
  }
}

void _showDownPathDialog(BuildContext context, VoidCallback setState) {
  showDialog(
    context: context,
    builder: (_) => SimpleDialog(
      clipBehavior: Clip.hardEdge,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        DialogOption(
          onPressed: () {
            Get.back();
            PathUtils.openDir(downloadPath);
          },
          child: const Text('打开'),
        ),
        DialogOption(
          onPressed: () {
            Get.back();
            Utils.copyText(downloadPath);
          },
          child: const Text('复制', style: TextStyle(fontSize: 14)),
        ),
        DialogOption(
          onPressed: () async {
            Get.back();
            final defPath = defDownloadPath;
            await _setDownloadPath(context, setState, defPath);
          },
          child: const Text('重置', style: TextStyle(fontSize: 14)),
        ),
        DialogOption(
          onPressed: () async {
            Get.back();
            try {
              final path = await FilePicker.getDirectoryPath(
                initialDirectory: Directory(downloadPath).existsSync()
                    ? downloadPath
                    : null,
              );
              if (path == null || !context.mounted) return;
              await _setDownloadPath(context, setState, path);
            } catch (error, stack) {
              logger.e('下载目录选择失败', error: error.runtimeType, stackTrace: stack);
              if (context.mounted) SmartDialog.showToast('下载目录选择失败，请重试');
            }
          },
          child: const Text('设置新路径', style: TextStyle(fontSize: 14)),
        ),
      ],
    ),
  );
}

Future<void> _showReplyCountDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('连接重试次数'),
      min: 0,
      max: 8,
      divisions: 8,
      precise: 0,
      value: Pref.retryCount.toDouble(),
    ),
  );
  if (res != null) {
    if (!context.mounted) return;
    await saveSetting(
      key: SettingBoxKey.retryCount,
      write: () => GStorage.setting.put(SettingBoxKey.retryCount, res.toInt()),
      apply: setState,
      canPresent: () => context.mounted,
      successMessage: '重启生效',
    );
  }
}

Future<void> _showReplyDelayDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(
      title: const Text('连接重试间隔'),
      min: 0,
      max: 1000,
      divisions: 10,
      precise: 0,
      value: Pref.retryDelay.toDouble(),
      suffix: 'ms',
    ),
  );
  if (res != null) {
    if (!context.mounted) return;
    await saveSetting(
      key: SettingBoxKey.retryDelay,
      write: () => GStorage.setting.put(SettingBoxKey.retryDelay, res.toInt()),
      apply: setState,
      canPresent: () => context.mounted,
      successMessage: '重启生效',
    );
  }
}

void _showProxyDialog(BuildContext context) {
  String systemProxyHost = Pref.systemProxyHost;
  String systemProxyPort = Pref.systemProxyPort;

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('设置代理'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          TextFormField(
            initialValue: systemProxyHost,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '请输入Host，使用 . 分割',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
            ),
            onChanged: (e) => systemProxyHost = e,
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: systemProxyPort,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '请输入Port',
              border: OutlineInputBorder(borderRadius: .all(.circular(6))),
            ),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (e) => systemProxyPort = e,
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
          onPressed: () async {
            final port = int.tryParse(systemProxyPort);
            if (systemProxyHost.trim().isEmpty ||
                port == null ||
                port < 1 ||
                port > 65535) {
              SmartDialog.showToast('请输入有效的 Host 和 1–65535 范围内的 Port');
              return;
            }
            final saved = await saveSetting(
              key: SettingBoxKey.systemProxyHost,
              write: () => GStorage.setting.putAll({
                SettingBoxKey.systemProxyHost: systemProxyHost.trim(),
                SettingBoxKey.systemProxyPort: systemProxyPort,
              }),
              canPresent: () => context.mounted,
            );
            if (saved &&
                context.mounted &&
                (ModalRoute.of(context)?.isCurrent ?? false)) {
              Navigator.pop(context);
            }
          },
          child: const Text('确认'),
        ),
      ],
    ),
  );
}

void _showCacheDialog(BuildContext context, VoidCallback setState) {
  String valueStr = '';
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('最大缓存大小'),
      content: TextField(
        maxLength: 6,
        autofocus: true,
        onChanged: (value) => valueStr = value,
        keyboardType: TextInputType.number,
        inputFormatters: FilteringText.decimal,
        decoration: const InputDecoration(suffixText: 'MB'),
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
              final val = num.parse(valueStr);
              if (!val.isFinite || val < 0) throw const FormatException();
              final saved = await saveSetting(
                key: SettingBoxKey.maxCacheSize,
                write: () => GStorage.setting.put(
                  SettingBoxKey.maxCacheSize,
                  val * 1024 * 1024,
                ),
                apply: setState,
                canPresent: () => context.mounted,
              );
              if (saved &&
                  context.mounted &&
                  (ModalRoute.of(context)?.isCurrent ?? false)) {
                Navigator.pop(context);
              }
            } on FormatException {
              SmartDialog.showToast('请输入有效的非负缓存大小');
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
