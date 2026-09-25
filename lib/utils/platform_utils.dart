import 'dart:io' show Platform;

abstract final class PlatformUtils {
  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid;

  @pragma("vm:platform-const")
  static final bool isDesktop = Platform.isWindows;
}
