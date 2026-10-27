import 'package:flutter/services.dart';

/// Restart Manager 的退出请求直接进入清理流程，跳过关闭窗口后的托盘行为。
abstract final class WindowsUpdateExit {
  static const _channel = MethodChannel('piliaurora/update_exit');

  static void setHandler(Future<void> Function()? onClose) {
    _channel.setMethodCallHandler(
      onClose == null
          ? null
          : (call) async {
              if (call.method != 'closeForUpdate') {
                throw MissingPluginException();
              }
              await onClose();
            },
    );
  }
}
