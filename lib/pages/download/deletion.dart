import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage.dart';

/// 页面持有删除锁；下载文件删除成功后才清理播放记录和页面快照。
class DownloadDeletion {
  bool busy = false;

  Future<Set<T>> run<T>({
    required Iterable<T> items,
    required Future<LoadingState<void>> Function(T) delete,
    required Iterable<BiliDownloadEntryInfo> Function(T) entries,
    required bool Function() isCurrent,
    void Function(T)? onDeleted,
    bool showLoading = false,
  }) async {
    if (busy || !isCurrent()) return {};
    final snapshot = items.toList();
    if (snapshot.isEmpty) return {};
    busy = true;
    final removed = <T>{};
    try {
      if (showLoading) SmartDialog.showLoading();
      for (final item in snapshot) {
        if (!isCurrent()) break;
        LoadingState<void> result;
        try {
          result = await delete(item);
        } catch (error, stackTrace) {
          logger.w('删除下载失败', error: error.runtimeType, stackTrace: stackTrace);
          result = Error('删除失败，请重试', cause: error, stackTrace: stackTrace);
        }
        if (!result.isSuccess) {
          if (isCurrent()) result.toast();
          continue;
        }
        removed.add(item);
        try {
          await GStorage.watchProgress.deleteAll(
            entries(item).map((e) => e.cid.toString()),
          );
        } catch (error, stackTrace) {
          logger.w(
            '下载已删除，播放记录清理失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
          if (isCurrent()) SmartDialog.showToast('下载已删除，播放记录清理失败');
        }
        if (isCurrent()) {
          try {
            onDeleted?.call(item);
          } catch (error, stackTrace) {
            logger.w(
              '下载已删除，页面刷新失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
            SmartDialog.showToast('下载已删除，请刷新列表');
          }
        }
      }
    } finally {
      try {
        if (showLoading) await SmartDialog.dismiss(status: SmartStatus.loading);
      } catch (error, stackTrace) {
        logger.w(
          '下载删除提示关闭失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      } finally {
        busy = false;
      }
    }
    return removed;
  }
}
