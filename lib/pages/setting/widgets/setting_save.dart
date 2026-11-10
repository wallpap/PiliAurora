import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/services/logger.dart';

final _saving = <String>{};
final _presentationKey = Object();

Future<void> withSettingPresentation(
  bool Function() canPresent,
  FutureOr<void> Function() action,
) async => runZoned(action, zoneValues: {_presentationKey: canPresent});

/// 保存确认后才应用运行时状态；应用失败保留已落盘结果。
Future<bool> saveSetting({
  required String key,
  required Future<void> Function() write,
  FutureOr<void> Function()? apply,
  required bool Function() canPresent,
  String? successMessage,
}) async {
  final sourceIsCurrent = Zone.current[_presentationKey] as bool Function()?;
  bool present() => canPresent() && (sourceIsCurrent?.call() ?? true);
  if (!_saving.add(key)) return false;
  try {
    try {
      await write();
    } catch (error, stack) {
      logger.w('保存设置失败', error: error.runtimeType, stackTrace: stack);
      if (present()) SmartDialog.showToast('设置保存失败，请重试');
      return false;
    }
    try {
      await apply?.call();
    } catch (error, stack) {
      logger.w('应用已保存的设置失败', error: error.runtimeType, stackTrace: stack);
      if (present()) SmartDialog.showToast('设置已保存，应用失败，请重启后重试');
      return true;
    }
    if (successMessage != null && present()) {
      SmartDialog.showToast(successMessage);
    }
    return true;
  } finally {
    _saving.remove(key);
  }
}
