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
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SubController extends CommonListController<SubData, SubItemModel> {
  Account get account => Accounts.main;
  final isCleaning = false.obs;
  final cleanupProgress = ''.obs;
  final _canceling = <(int, int), Object>{};
  Object? _cleanupOwner;
  bool _closed = false;
  static const _pageSize = 20;

  bool _ownsAccount(Account owner) =>
      !_closed && !isClosed && identical(owner, Accounts.main);

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    _cleanupOwner = null;
    _canceling.clear();
    isCleaning.value = false;
    cleanupProgress.value = '';
    onReload();
  }

  @override
  void onClose() {
    _closed = true;
    _cleanupOwner = null;
    _canceling.clear();
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (_closed || isCleaning.value) return Future.value();
    if (!account.isLogin) {
      loadingState.value = const Error('账号未登录');
      return Future.value();
    }
    return super.queryData(isRefresh);
  }

  Future<void> cancelSub(SubItemModel item) async {
    final owner = account;
    final source = loadingState.value.dataOrNull;
    final id = item.id;
    final type = item.type;
    if (!_ownsAccount(owner) ||
        !owner.isLogin ||
        isCleaning.value ||
        isLoading ||
        id == null ||
        id <= 0 ||
        !const [11, 21].contains(type) ||
        source == null ||
        !source.contains(item)) {
      return;
    }
    final key = (type!, id);
    if (_canceling.containsKey(key)) return;
    var submitting = false;
    await showDialog<void>(
      context: Get.context!,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('提示'),
          content: const Text('确定取消订阅吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (submitting ||
                          _canceling.containsKey(key) ||
                          isCleaning.value) {
                        return;
                      }
                      if (!_ownsAccount(owner) ||
                          isLoading ||
                          !identical(source, loadingState.value.dataOrNull)) {
                        SmartDialog.showToast('账号或订阅已更新，请重新打开');
                        return;
                      }
                      final operation = _canceling[key] = Object();
                      final route = ModalRoute.of(dialogContext);
                      setState(() => submitting = true);
                      bool current() =>
                          _ownsAccount(owner) &&
                          dialogContext.mounted &&
                          route?.isCurrent == true;
                      try {
                        final result = await FavHttp.cancelSub(
                          account: owner,
                          id: id,
                          type: type,
                        );
                        if (result.isSuccess) {
                          var localFailed = false;
                          try {
                            await HiddenSubscriptionMedia(
                              GStorage.localCache,
                              owner.mid,
                            ).remove(type, id);
                          } catch (error, stackTrace) {
                            localFailed = true;
                            logger.w(
                              '订阅已取消，本地隐藏记录清理失败',
                              error: error.runtimeType,
                              stackTrace: stackTrace,
                            );
                          }
                          if (_ownsAccount(owner)) {
                            if (!isLoading &&
                                identical(
                                  source,
                                  loadingState.value.dataOrNull,
                                )) {
                              source.removeWhere(
                                (row) => row.id == id && row.type == type,
                              );
                              loadingState.refresh();
                            } else {
                              try {
                                await onRefresh();
                              } catch (error, stackTrace) {
                                logger.w(
                                  '订阅已取消，列表刷新失败',
                                  error: error.runtimeType,
                                  stackTrace: stackTrace,
                                );
                              }
                            }
                          }
                          if (dialogContext.mounted && current()) {
                            Navigator.of(dialogContext).pop();
                            SmartDialog.showToast(
                              localFailed ? '取消订阅成功，本地记录清理失败' : '取消订阅成功',
                            );
                          }
                        } else if (current()) {
                          result.toast();
                        }
                      } catch (error, stackTrace) {
                        logger.w(
                          '取消订阅处理失败',
                          error: error.runtimeType,
                          stackTrace: stackTrace,
                        );
                        if (current()) {
                          UnknownResult(
                            cause: error,
                            stackTrace: stackTrace,
                          ).toast();
                        }
                      } finally {
                        if (identical(_canceling[key], operation)) {
                          _canceling.remove(key);
                        }
                        if (context.mounted) setState(() => submitting = false);
                      }
                    },
              child: Text(submitting ? '提交中' : '确定'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> cleanInvalidSubscriptions() async {
    final requestAccount = account;
    if (_closed ||
        isCleaning.value ||
        isLoading ||
        _canceling.isNotEmpty ||
        !requestAccount.isLogin) {
      return;
    }
    final owner = _cleanupOwner = Object();
    bool isCurrent() =>
        _ownsAccount(requestAccount) && identical(_cleanupOwner, owner);
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
      if (!confirmed || !isCurrent()) return;
      cleanupProgress.value = '正在读取全部订阅';
      final mid = requestAccount.mid;
      final snapshot = await loadSubscriptionSnapshot(
        (page) => isCurrent()
            ? UserHttp.userSubFolder(
                account: requestAccount,
                mid: mid,
                pn: page,
                ps: _pageSize,
              )
            : Future.value(const Error('账号已切换')),
      );
      if (!isCurrent()) return;
      if (snapshot is! Success<List<SubItemModel>>) {
        await snapshot.toast();
        return;
      }
      final hidden = HiddenSubscriptionMedia(GStorage.localCache, mid);
      var localFailures = 0;
      final cleaner = SubscriptionCleaner(
        loadContents: (item, page) => isCurrent()
            ? _loadSubscriptionContents(requestAccount, item, page)
            : Future.value(const Error('账号已切换')),
        checkVideo: (aid) => isCurrent()
            ? FavHttp.subscriptionVideoAvailable(aid, account: requestAccount)
            : Future.value(const Error('账号已切换')),
        cancel: (item) async {
          if (!isCurrent()) return const Error('账号已切换');
          final response = await FavHttp.cancelSub(
            account: requestAccount,
            id: item.id!,
            type: item.type!,
          );
          if (response.isSuccess) {
            try {
              await hidden.remove(item.type!, item.id!);
            } catch (error, stackTrace) {
              localFailures++;
              logger.w(
                '订阅已取消，本地隐藏记录清理失败',
                error: error.runtimeType,
                stackTrace: stackTrace,
              );
            }
          }
          return response;
        },
        saveHidden: (item, media) => isCurrent()
            ? hidden.add(item.type!, item.id!, media)
            : Future.value(0),
      );
      final result = await cleaner.run(
        snapshot.response,
        hideInvalid: hideInvalid,
        isCurrent: isCurrent,
        onProgress: (processed, total) {
          if (isCurrent()) cleanupProgress.value = '正在检查 $processed/$total 个订阅';
        },
      );
      if (!isCurrent()) return;
      final summary =
          result.removed == 0 &&
              result.hidden == 0 &&
              result.failed == 0 &&
              result.pending == 0
          ? '没有需要清理的失效内容'
          : '已取消 ${result.removed} 个订阅'
                '${hideInvalid ? '，本地隐藏 ${result.hidden} 个失效视频' : ''}'
                '${result.failed > 0 ? '；${result.failed} 个订阅清理失败' : ''}'
                '${result.pending > 0 ? '；${result.pending} 个取消结果待确认，请刷新订阅核对' : ''}'
                '${localFailures > 0 ? '；$localFailures 项本地记录清理失败' : ''}';
      SmartDialog.showToast(summary);
      // 清理锁只保护扫描和写入，刷新须能实际发起请求。
      isCleaning.value = false;
      await onRefresh();
    } catch (error, stackTrace) {
      logger.w('订阅清理未完成', error: error.runtimeType, stackTrace: stackTrace);
      if (isCurrent()) SmartDialog.showToast('清理未完成，请刷新核对订阅状态');
    } finally {
      if (identical(_cleanupOwner, owner)) {
        _cleanupOwner = null;
        isCleaning.value = false;
        cleanupProgress.value = '';
      }
    }
  }

  Future<LoadingState<SubscriptionContentPage>> _loadSubscriptionContents(
    Account requestAccount,
    SubItemModel item,
    int page,
  ) async {
    if (item.type == 11) {
      final result = await FavHttp.userFavFolderDetail(
        account: requestAccount,
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
      account: requestAccount,
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
    account: account,
    pn: page,
    ps: _pageSize,
    mid: account.mid,
  );
}
