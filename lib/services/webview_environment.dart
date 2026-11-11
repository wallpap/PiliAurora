import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 启动时只登记目录；第一次网页或 Cookie 操作共享同一份初始化。
abstract final class AppWebViewEnvironment {
  static WebViewEnvironment? _instance;
  static WebViewEnvironment? get instance => _instance;
  static String? _userDataPath;
  static Future<void>? _initializing;
  static bool get isConfigured => _userDataPath != null;

  static void configure({required String userDataPath}) {
    if (_userDataPath != null && _userDataPath != userDataPath) {
      throw StateError('WebView directory already configured');
    }
    _userDataPath = userDataPath;
  }

  static Future<void> initialize({required String userDataPath}) async {
    configure(userDataPath: userDataPath);
    await ensureInitialized();
  }

  static Future<void> ensureInitialized() {
    // 非 Windows 不登记目录，继续使用平台自己的默认环境。
    if (_userDataPath == null || _instance != null) return Future.value();
    return _initializing ??= _create();
  }

  static Future<void> _create() async {
    try {
      if (await WebViewEnvironment.getAvailableVersion() != null) {
        _instance = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _userDataPath!),
        );
      }
    } finally {
      // 失败后允许显式重试，不让失败的 Future 固化整个应用生命周期。
      _initializing = null;
    }
  }
}
