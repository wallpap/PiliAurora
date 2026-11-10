import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/common/widgets/loading_widget.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/logger.dart';

abstract interface class WebpConversion {
  Future<bool> convert();
  Future<void> dispose();
}

/// 配置弹窗之上打开新页面时，底层 Get 路由观察器不会收到覆盖事件。
final class WebpCaptureDialogRoute extends DialogRoute<bool> {
  WebpCaptureDialogRoute({
    required super.context,
    required super.builder,
    required this.operation,
  });

  final WebpCaptureOperation operation;

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute is PageRoute) {
      // 导航回调内不能立即修改同一个 Navigator。
      scheduleMicrotask(() => unawaited(operation.cancel()));
    }
  }
}

/// 动态截图仅持有自己的暂停令牌、转换器、临时目录及进度提示。
final class WebpCaptureOperation with RouteAware {
  WebpCaptureOperation({required this.owner, required this.ownsSource});

  final PlaybackOwner owner;
  final bool Function() ownsSource;
  final progress = 0.0.obs;
  final _tag = 'webp-capture-${UniqueKey()}';
  PlaybackInhibitorToken? _inhibitor;
  StreamSubscription<PlaybackSnapshot>? _subscription;
  WebpConversion? _conversion;
  Directory? _directory;
  Future<void>? _cleanup;
  bool _cancelled = false;
  bool _loading = false;
  VoidCallback? onCancel;

  bool get isCurrent => !_cancelled && owner.isActive && ownsSource();

  Future<void> run(Future<void> Function() capture) async {
    if (!isCurrent) return;
    if (Get.routing.route case final GetPageRoute route) {
      routeObserver.subscribe(this, route);
    }
    _inhibitor = owner.acquireInhibitor(PlaybackInhibitorSource.system);
    if (_inhibitor == null) {
      routeObserver.unsubscribe(this);
      return;
    }
    _subscription = owner.snapshots.listen(
      (_) {
        if (!isCurrent) unawaited(cancel());
      },
      onError: (Object error, StackTrace stackTrace) {
        _log('动态截图播放状态读取失败', error, stackTrace);
        unawaited(cancel());
      },
      onDone: () => unawaited(cancel()),
    );
    try {
      await capture();
    } catch (error, stackTrace) {
      _log('动态截图失败', error, stackTrace);
      if (isCurrent) SmartDialog.showToast('动态截图失败，请重试');
    } finally {
      await cancel();
      // 保存平台可能仍在读取文件；取消只停止转换，文件等保存回执后再清理。
      await _guard('动态截图临时文件清理失败', () async {
        await _directory?.delete(recursive: true);
      });
    }
  }

  Future<String?> createFile(String root, String name) async {
    if (!isCurrent) return null;
    final directory = await Directory(root).createTemp('webp-capture-');
    // 创建期间也可能离页；目录此时仍由本操作负责回收。
    if (!isCurrent) {
      await directory.delete(recursive: true);
      return null;
    }
    _directory = directory;
    return '${directory.path}${Platform.pathSeparator}$name';
  }

  Future<bool> convert(WebpConversion conversion) async {
    if (!isCurrent) {
      await conversion.dispose();
      return false;
    }
    _conversion = conversion;
    _loading = true;
    SmartDialog.show<void>(
      tag: _tag,
      builder: (_) => LoadingWidget(
        progress: progress,
        msg: '正在保存，可能需要较长时间',
      ),
      debounce: false,
      clickMaskDismiss: false,
      backType: SmartBackType.normal,
      onDismiss: () {
        if (_loading) unawaited(cancel());
      },
    );
    final success = await conversion.convert();
    await _closeLoading();
    if (!success && isCurrent) SmartDialog.showToast('转码失败，请重试');
    return success && isCurrent;
  }

  Future<void> cancel() {
    if (_cleanup case final cleanup?) return cleanup;
    _cancelled = true;
    routeObserver.unsubscribe(this);
    try {
      onCancel?.call();
    } catch (error, stackTrace) {
      _log('关闭动态截图设置失败', error, stackTrace);
    }
    onCancel = null;
    return _cleanup = _close();
  }

  Future<void> _close() async {
    await _guard('动态截图状态订阅释放失败', () async {
      await _subscription?.cancel();
    });
    // 只移除自己的抑制，不补发 play；用户的新暂停及新源意图仍由会话决定。
    await _guard('动态截图暂停令牌释放失败', () async {
      if (_inhibitor case final token?) {
        final result = await owner.releaseInhibitor(token);
        if (result.outcome == CommandOutcome.failed) {
          logger.w('动态截图暂停令牌释放失败: ${result.failure?.category.name}');
          if (owner.isActive && ownsSource()) {
            SmartDialog.showToast('播放恢复失败，请手动播放');
          }
        }
      }
    });
    await _closeLoading();
    await _guard('动态截图转换器释放失败', () async {
      await _conversion?.dispose();
    });
  }

  Future<void> _closeLoading() async {
    if (!_loading) return;
    _loading = false;
    await _guard('关闭动态截图进度失败', () => SmartDialog.dismiss(tag: _tag));
  }

  static Future<void> _guard(
    String message,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      _log(message, error, stackTrace);
    }
  }

  static void _log(String message, Object error, StackTrace stackTrace) =>
      logger.w(message, error: error.runtimeType, stackTrace: stackTrace);

  @override
  void didPushNext() => unawaited(cancel());

  @override
  void didPop() => unawaited(cancel());
}
