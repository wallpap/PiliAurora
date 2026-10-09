import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

/// 仅首次使用或用户手动校准时写入。设置导入后的值原样保留；绝不监听旋转。
abstract final class AndroidVideoCalibration {
  static VideoOutputSize? get saved {
    final raw = GStorage.setting.get(
      SettingBoxKey.androidFullscreenCalibration,
    );
    if (raw is! Map) return null;
    final width = raw['width'];
    final height = raw['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      return null;
    }
    return (width: width, height: height);
  }

  static Future<VideoOutputSize> ensure() async => saved ?? await recalibrate();

  static Future<VideoOutputSize> recalibrate({ui.FlutterView? view}) async {
    final current =
        view ?? WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (current == null) {
      throw StateError('No display available for calibration');
    }
    // Display.size 为物理像素，不使用分屏/PiP/旋转后的当前 FlutterView 尺寸。
    // 默认沉浸式全屏画布等于显示区域；统一长/短边保存为横屏基准。
    final display = current.display;
    final width = display.size.longestSide.round();
    final height = display.size.shortestSide.round();
    if (width <= 0 || height <= 0) {
      throw StateError('Invalid fullscreen display size');
    }
    final record = <String, Object?>{
      'width': width,
      'height': height,
      'displayId': display.id,
      'devicePixelRatio': display.devicePixelRatio,
      'calibratedAt': DateTime.now().toUtc().toIso8601String(),
      'policy': 'default-immersive-fullscreen-physical-pixels',
    };
    await GStorage.setting.put(
      SettingBoxKey.androidFullscreenCalibration,
      record,
    );
    Diagnostics.instance.playerLog(
      DiagnosticLogLevel.info,
      'video.calibration',
      'fullscreen.calibrated',
      details: record,
    );
    return (width: width, height: height);
  }
}
