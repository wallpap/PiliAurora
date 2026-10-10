import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/sub/sub/data.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/pages/subscription/cleanup.dart';
import 'package:pili_aurora/pages/subscription/hidden_media.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SubController extends CommonListController<SubData, SubItemModel> {
  late final account = Accounts.main;
  final isCleaning = false.obs;
  final cleanupProgress = ''.obs;
  static const _pageSize = 20;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isCleaning.value) return Future.value();
    if (!account.isLogin) {
      loadingState.value = const Error('账号未登录');
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  // 取消订阅
  void cancelSub(SubItemModel subFolderItem) {
    if (isCleaning.value) return;
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: const Text('确定取消订阅吗？'),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              final res = await FavHttp.cancelSub(
                id: subFolderItem.id!,
                type: subFolderItem.type!,
              );
              if (res.isSuccess) {
                await HiddenSubscriptionMedia(
                  GStorage.localCache,
                  account.mid,
                ).remove(subFolderItem.type!, subFolderItem.id!);
                loadingState
                  ..value.data!.remove(subFolderItem)
                  ..refresh();
                SmartDialog.showToast('取消订阅成功');
              } else {
                res.toast();
              }
              Get.back();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> cleanInvalidSubscriptions() async {
    if (isCleaning.value || !account.isLogin) return;
    isCleaning.value = true;
    try {
      final hideInvalid = Pref.hideInvalidSubscriptionVideos;
      final confirmed = await showConfirmDialog(
        context: Get.context!,
        title: const Text('清除失效内容'),
        content: Text(
          '扫描全部订阅，取消已失效或全部内容失效的订阅。\n'
          '${hideInvalid ? '有效订阅中的失效视频将本地隐藏，有效内容保留。' : '保留仍有有效内容的订阅。可在“设置 → 其他设置”开启本地隐藏失效视频。'}',
        ),
      );
      if (!confirmed || isClosed) return;
      cleanupProgress.value = '正在读取全部订阅';
      final mid = account.mid;
      bool isCurrent() => !isClosed && Accounts.main.mid == mid;
      final snapshot = await loadSubscriptionSnapshot(
        (page) => isCurrent()
            ? UserHttp.userSubFolder(mid: mid, pn: page, ps: _pageSize)
            : Future.value(const Error('账号已切换')),
      );
      if (!isCurrent()) return;
      if (snapshot is! Success<List<SubItemModel>>) {
        await snapshot.toast();
        return;
      }
      final hidden = HiddenSubscriptionMedia(GStorage.localCache, mid);
      final cleaner = SubscriptionCleaner(
        loadContents: _loadSubscriptionContents,
        checkVideo: FavHttp.subscriptionVideoAvailable,
        cancel: (item) async {
          if (!isCurrent()) return const Error('账号已切换');
          final response = await FavHttp.cancelSub(
            id: item.id!,
            type: item.type!,
          );
          if (response.isSuccess) await hidden.remove(item.type!, item.id!);
          return response;
        },
        saveHidden: (item, media) => hidden.add(item.type!, item.id!, media),
      );
      final result = await cleaner.run(
        snapshot.response,
        hideInvalid: hideInvalid,
        isCurrent: isCurrent,
        onProgress: (processed, total) {
          if (!isClosed) cleanupProgress.value = '正在检查 $processed/$total 个订阅';
        },
      );
      if (!isCurrent()) return;
      final summary =
          result.removed == 0 && result.hidden == 0 && result.failed == 0
          ? '没有需要清理的失效内容'
          : '已取消 ${result.removed} 个订阅'
                '${hideInvalid ? '，本地隐藏 ${result.hidden} 个失效视频' : ''}'
                '${result.failed > 0 ? '；${result.failed} 个订阅未能完成清理，可稍后重试' : ''}';
      SmartDialog.showToast(summary);
      await onRefresh();
    } catch (_) {
      if (!isClosed) SmartDialog.showToast('清理未完成，请稍后重试');
    } finally {
      isCleaning.value = false;
      cleanupProgress.value = '';
    }
  }

  Future<LoadingState<SubscriptionContentPage>> _loadSubscriptionContents(
    SubItemModel item,
    int page,
  ) async {
    if (item.type == 11) {
      final result = await FavHttp.userFavFolderDetail(
        mediaId: item.id!,
        pn: page,
        ps: _pageSize,
      );
      if (result is Error) return result;
      if (result is! Success) return const Error('收藏夹尚未加载完成');
      final data = result.data;
      final medias = data.medias;
      if (medias == null && (data.info?.mediaCount ?? 0) > 0) {
        return const Error('收藏夹内容响应不完整');
      }
      if (data.hasMore == null) return const Error('收藏夹分页信息不完整');
      return Success(
        SubscriptionContentPage(
          items: [
            for (final media in medias ?? [])
              (
                id: media.id ?? 0,
                type: media.type ?? 2,
                valid: const [1, 9].contains(media.attr)
                    ? false
                    : media.attr != null ||
                          (media.type != null && media.type != 2)
                    ? true
                    : null,
              ),
          ],
          hasMore: data.hasMore!,
          total: data.info?.mediaCount,
        ),
      );
    }
    final result = await FavHttp.favSeasonList(
      id: item.id!,
      pn: page,
      ps: _pageSize,
    );
    if (result is Error) return result;
    if (result is! Success) return const Error('合集尚未加载完成');
    final data = result.data;
    final medias = data.medias;
    if (medias == null && (data.info?.mediaCount ?? 0) > 0) {
      return const Error('合集内容响应不完整');
    }
    final count = data.info?.mediaCount;
    return Success(
      SubscriptionContentPage(
        items: [
          for (final media in medias ?? [])
            (id: media.id ?? 0, type: 2, valid: null),
        ],
        hasMore: count != null
            ? page * _pageSize < count
            : (medias?.length ?? 0) >= _pageSize,
        total: count,
      ),
    );
  }

  @override
  List<SubItemModel>? getDataList(SubData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.list;
  }

  @override
  Future<LoadingState<SubData>> customGetData() => UserHttp.userSubFolder(
    pn: page,
    ps: _pageSize,
    mid: account.mid,
  );
}
