import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';

abstract final class ConnectivityUtils {
  /// 初始化可保守降级；保存按网络区分的偏好须消费 [queryWiFi] 的明确结果。
  static Future<bool> get isWiFi async =>
      (await queryWiFi()).dataOrNull ?? false;

  static Future<LoadingState<bool>> queryWiFi() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const Success(false);
    }
    try {
      return Success(
        (await Connectivity().checkConnectivity()).contains(
          ConnectivityResult.wifi,
        ),
      );
    } catch (error, stackTrace) {
      logger.w('网络类型探测失败', error: error.runtimeType, stackTrace: stackTrace);
      return Error('无法确认网络类型，请稍后重试', cause: error, stackTrace: stackTrace);
    }
  }
}
