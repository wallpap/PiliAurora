import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter/services.dart' show HapticFeedback;

bool enableFeedback = Pref.feedBackEnable;
Future<void> feedBack() async {
  if (!enableFeedback) return;
  try {
    await HapticFeedback.lightImpact();
  } catch (error, stackTrace) {
    // 触感属于附带反馈，设备失败不影响用户正在执行的操作。
    logger.w('触感反馈失败', error: error.runtimeType, stackTrace: stackTrace);
  }
}
