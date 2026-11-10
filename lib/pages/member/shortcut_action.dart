import 'dart:io' show File;

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart' show UniqueKey;
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';

/// 页面持有操作；系统仅接收创建请求，最终添加由启动器与用户确认。
class MemberShortcutAction {
  MemberShortcutAction({
    Future<File> Function(String)? loadIcon,
    void Function(String, String, String, String)? requestShortcut,
  }) : _loadIcon = loadIcon ?? CacheManager.manager.getSingleFile,
       _requestShortcut = requestShortcut ?? PiliAndroidHelper.createShortcut;

  final Future<File> Function(String) _loadIcon;
  final void Function(String, String, String, String) _requestShortcut;
  bool _running = false;

  Future<void> run({
    required int mid,
    required String? username,
    required String? avatar,
    required bool Function() isCurrent,
  }) async {
    if (_running || !isCurrent()) return;
    if (username == null ||
        username.isEmpty ||
        avatar == null ||
        avatar.isEmpty) {
      SmartDialog.showToast('请先加载空间资料后重试');
      return;
    }
    _running = true;
    final tag = 'member-shortcut-${UniqueKey()}';
    var cancelled = false;
    var closing = false;
    try {
      SmartDialog.show<void>(
        tag: tag,
        builder: (_) => const LoadingWidget('正在创建快捷方式'),
        debounce: false,
        clickMaskDismiss: false,
        backType: SmartBackType.normal,
        onDismiss: () {
          if (!closing) cancelled = true;
        },
      );
      final file = await _loadIcon('$avatar@200w_200h.webp'.http2https);
      if (!isCurrent() || cancelled) return;
      _requestShortcut('$mid', 'bilibili://space/$mid', username, file.path);
    } catch (error, stack) {
      logger.w('请求空间快捷方式失败', error: error.runtimeType, stackTrace: stack);
      if (isCurrent() && !cancelled) {
        SmartDialog.showToast('创建快捷方式失败，请重试');
      }
    } finally {
      closing = true;
      try {
        await SmartDialog.dismiss(tag: tag);
      } catch (error, stack) {
        logger.w('关闭快捷方式提示失败', error: error.runtimeType, stackTrace: stack);
      }
      _running = false;
    }
  }
}
