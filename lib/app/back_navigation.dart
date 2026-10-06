import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

KeyEventResult handleAppKeyEvent(KeyEvent event) {
  if (event.logicalKey == .escape && event is KeyDownEvent) {
    handleAppBack();
    return .handled;
  }
  return .ignored;
}

void handleAppBack() {
  if (SmartDialog.checkExist()) {
    SmartDialog.dismiss();
    return;
  }

  final route = Get.routing.route;
  if (route is GetPageRoute) {
    if (route.popDisposition == .doNotPop) {
      route.onPopInvokedWithResult(false, null);
      return;
    }
  }

  final navigator = Get.key.currentState!;
  if (navigator.canPop()) {
    navigator.pop();
  }
}
