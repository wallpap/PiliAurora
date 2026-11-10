import 'package:pili_aurora/services/logger.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/pages/setting/widgets/normal_item.dart';
import 'package:pili_aurora/utils/cache_manager.dart';

class ClearCacheItem extends StatefulWidget {
  const ClearCacheItem({super.key});

  @override
  State<ClearCacheItem> createState() => _ClearCacheItemState();
}

class _ClearCacheItemState extends State<ClearCacheItem> {
  String _cacheSize = '';
  bool _readFailed = false;
  bool _busy = false;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final version = ++_loadVersion;
    try {
      final size = await CacheManager.loadApplicationCache();
      if (mounted && version == _loadVersion) {
        setState(() {
          _readFailed = false;
          _cacheSize = CacheManager.formatSize(size);
        });
      }
    } catch (error, stackTrace) {
      logger.w('缓存大小读取失败', error: error.runtimeType, stackTrace: stackTrace);
      if (mounted && version == _loadVersion) {
        setState(() {
          _readFailed = true;
          _cacheSize = '读取失败，点击重试';
        });
      }
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final confirmed = await showConfirmDialog(
        context: context,
        title: const Text('提示'),
        content: const Text('该操作将清除图片及网络请求缓存数据，确认清除？'),
      );
      if (!confirmed || !mounted) return;
      _loadVersion++;
      SmartDialog.showLoading(msg: '正在清除...');
      String message;
      try {
        await CacheManager.clearLibraryCache();
        message = '清除成功';
      } catch (error, stackTrace) {
        logger.w('缓存未完全清除', error: error.runtimeType, stackTrace: stackTrace);
        message = '部分缓存未能清除，请稍后重试';
      } finally {
        await SmartDialog.dismiss(status: .loading);
      }
      if (mounted) {
        SmartDialog.showToast(message);
        await _loadCacheSize();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => NormalItem(
    title: '清除缓存',
    subtitle: '图片及网络缓存 $_cacheSize',
    leading: const Icon(Icons.delete_outline),
    onTap: _busy || _cacheSize.isEmpty
        ? null
        : (context, _) {
            if (_readFailed) {
              _loadCacheSize();
            } else {
              _confirmClear(context);
            }
          },
  );
}
