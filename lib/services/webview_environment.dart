import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 由启动层初始化，页面和 Cookie 同步只读取同一个 WebView 环境。
abstract final class AppWebViewEnvironment {
  static WebViewEnvironment? _instance;
  static WebViewEnvironment? get instance => _instance;

  static Future<void> initialize({required String userDataPath}) async {
    if (_instance != null) return;
    if (await WebViewEnvironment.getAvailableVersion() != null) {
      _instance = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: userDataPath),
      );
    }
  }
}
