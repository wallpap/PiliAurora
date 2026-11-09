import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class HistoryBaseController extends GetxController {
  RxBool pauseStatus = false.obs;

  RxBool enableMultiSelect = false.obs;
  RxInt checkedCount = 0.obs;

  final account = Accounts.history;
  bool _saving = false;
  int _statusVersion = 0;

  bool get isCurrent => !isClosed && identical(account, Accounts.history);

  Future<void> _cachePauseStatus(bool paused) async {
    pauseStatus.value = paused;
    try {
      await GStorage.localCache.put(LocalCacheKey.historyPause, paused);
    } catch (error, stackTrace) {
      logger.w('观看历史状态缓存失败', error: error.runtimeType, stackTrace: stackTrace);
    }
  }

  Future<void> refreshHistoryStatus() async {
    if (!isCurrent || _saving) return;
    final version = ++_statusVersion;
    final result = await UserHttp.historyStatus(account: account);
    if (!isCurrent || version != _statusVersion) return;
    if (result case Success(:final response)) {
      await _cachePauseStatus(response);
    } else {
      result.toast();
    }
  }

  Future<void> clearHistory(VoidCallback onSuccess) async {
    if (_saving || !isCurrent) return;
    _saving = true;
    SmartDialog.showLoading(msg: '请求中');
    try {
      final result = await UserHttp.clearHistory(account: account);
      if (!isCurrent) return;
      if (result.isSuccess) {
        SmartDialog.showToast('已清空观看历史');
        onSuccess();
      } else {
        result.toast();
      }
    } finally {
      _saving = false;
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  Future<void> setHistoryPaused(bool paused) async {
    if (_saving || !isCurrent) return;
    _saving = true;
    ++_statusVersion;
    SmartDialog.showLoading(msg: '请求中');
    try {
      final result = await UserHttp.pauseHistory(paused, account: account);
      if (!isCurrent) return;
      if (result.isSuccess) {
        await _cachePauseStatus(paused);
        if (isCurrent) SmartDialog.showToast(paused ? '已暂停观看历史' : '已恢复观看历史');
      } else {
        result.toast();
      }
    } finally {
      _saving = false;
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  // 清空观看历史
  void onClearHistory(BuildContext context, VoidCallback onSuccess) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: const Text('啊叻？你要清空历史记录功能吗？'),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              clearHistory(onSuccess);
            },
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
  }

  // 暂停观看历史
  void onPauseHistory(BuildContext context) {
    final pauseStatus = !this.pauseStatus.value;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: Text(pauseStatus ? '啊叻？你要暂停历史记录功能吗？' : '啊叻？要恢复历史记录功能吗？'),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              setHistoryPaused(pauseStatus);
            },
            child: Text(pauseStatus ? '确认暂停' : '确认恢复'),
          ),
        ],
      ),
    );
  }
}
