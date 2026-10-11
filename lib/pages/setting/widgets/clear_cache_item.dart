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

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  void _loadCacheSize() {
    CacheManager.loadApplicationCache().then((size) {
      if (mounted) {
        setState(() => _cacheSize = CacheManager.formatSize(size));
      }
    });
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('提示'),
      content: const Text('该操作将清除图片及网络请求缓存数据，确认清除？'),
    );
    if (!confirmed) return;

    SmartDialog.showLoading(msg: '正在清除...');
    try {
      await CacheManager.clearLibraryCache();
      SmartDialog.showToast('清除成功');
    } catch (error) {
      SmartDialog.showToast(error.toString());
    } finally {
      SmartDialog.dismiss();
    }
    _loadCacheSize();
  }

  @override
  Widget build(BuildContext context) => NormalItem(
    title: '清除缓存',
    subtitle: '图片及网络缓存 $_cacheSize',
    leading: const Icon(Icons.delete_outline),
    onTap: _cacheSize.isEmpty ? null : (context, _) => _confirmClear(context),
  );
}
