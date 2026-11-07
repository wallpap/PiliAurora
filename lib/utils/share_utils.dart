import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:share_plus/share_plus.dart';

abstract final class ShareUtils {
  static Future<void> shareText(String text) async {
    if (PlatformUtils.isDesktop) {
      Utils.copyText(text);
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(text: text),
      );
    } catch (e) {
      SmartDialog.showToast(e.toString());
    }
  }
}
