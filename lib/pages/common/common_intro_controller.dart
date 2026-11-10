import 'dart:async' show FutureOr, Timer, unawaited;

import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/stat_detail.dart';
import 'package:pili_aurora/models/remote/video/video_tag/data.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonIntroController extends GetxController
    with GetSingleTickerProviderStateMixin, TripleMixin, FavMixin {
  late final String heroTag;
  late String bvid;

  // 是否稍后再看
  late final RxBool hasLater;

  final Rx<List<VideoTagItem>?> videoTags = Rx<List<VideoTagItem>?>(null);

  bool isProcessing = false;
  Future<void> handleAction(FutureOr Function() action) async {
    if (!isProcessing) {
      isProcessing = true;
      try {
        await action();
      } finally {
        isProcessing = false;
      }
    }
  }

  @override
  bool get isLogin => Accounts.main.isLogin;

  StatDetail? getStat();

  Object get interactionTarget => bvid;
  bool get interactionBusy => _interactionBusy;
  bool _interactionBusy = false;
  int interactionRevision = 0;

  bool ownsInteraction(Account account, Object target) =>
      !isClosed &&
      identical(account, Accounts.main) &&
      interactionTarget == target;

  /// 点赞、点踩、投币和三连会改动共同状态，串行执行并淘汰较早的状态查询。
  Future<void> runInteraction(
    Future<void> Function(Account account, bool Function() current) action,
  ) async {
    if (_interactionBusy || isClosed) return;
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final target = interactionTarget;
    bool current() => ownsInteraction(account, target);
    _interactionBusy = true;
    interactionRevision++;
    try {
      await action(account, current);
    } catch (error, stackTrace) {
      logger.w('视频互动未完成', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) const UnknownResult().toast();
    } finally {
      _interactionBusy = false;
      interactionRevision++;
    }
  }

  @override
  Future<void> Function(int, bool) get payCoinCallback {
    final account = Accounts.main;
    final target = interactionTarget;
    return (coin, withLike) async {
      if (!ownsInteraction(account, target)) {
        if (!isClosed) SmartDialog.showToast('视频或账号已更新，请重新打开投币面板');
        return;
      }
      await onPayCoin(coin, withLike);
    };
  }

  @override
  void updateFavCount(int count) {
    getStat()?.favorite += count;
  }

  final Rx<VideoDetailData> videoDetail = VideoDetailData().obs;

  void queryVideoIntro();

  bool prevPlay();
  bool nextPlay();

  void actionShareVideo(BuildContext context);

  // 同时观看
  final bool isShowOnlineTotal = Pref.enableOnlineTotal;
  late final RxString total = '1'.obs;
  Timer? timer;

  late final RxInt cid;

  late final videoDetailCtr = Get.find<VideoDetailController>(tag: heroTag);

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    heroTag = args['heroTag'];
    bvid = args['bvid'];
    cid = RxInt(args['cid']);
    hasLater = RxBool(
      args['viewLater'] ?? args['sourceType'] == SourceType.watchLater,
    );

    queryVideoIntro();
    startTimer();
  }

  void startTimer() {
    if (isShowOnlineTotal) {
      queryOnlineTotal();
      timer ??= Timer.periodic(const Duration(seconds: 10), (Timer timer) {
        queryOnlineTotal();
      });
    }
  }

  void cancelTimer() {
    timer?.cancel();
    timer = null;
  }

  // 查看同时在看人数
  Future<void> queryOnlineTotal() async {
    if (!isShowOnlineTotal) {
      return;
    }
    final result = await VideoHttp.onlineTotal(
      aid: IdUtils.bv2av(bvid),
      bvid: bvid,
      cid: cid.value,
    );
    if (result case Success(:final response)) {
      total.value = response;
    }
  }

  @override
  void onClose() {
    cancelTimer();
    super.onClose();
  }

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    await runInteraction((account, current) async {
      final limit = isHasCopyright(copyright) ? 2 : 1;
      if (coin > 0 && coinNum.value + coin > limit) {
        SmartDialog.showToast('达到投币上限啦~');
        return;
      }
      final res = await VideoHttp.coinVideo(
        bvid: bvid,
        multiply: coin,
        selectLike: coinWithLike ? 1 : 0,
        account: account,
      );
      // 余额属于发起账号；换视频后的已确认扣款仍然有效。
      if (res.isSuccess && identical(account, Accounts.main)) {
        GlobalData().afterCoin(coin);
      }
      if (!current()) return;
      if (res.isSuccess) {
        SmartDialog.showToast('投币成功');
        coinNum.value += coin;
        final stat = getStat();
        stat?.coin += coin;
        if (coinWithLike && !hasLike.value) {
          stat?.like++;
          hasLike.value = true;
        }
      } else {
        res.toast();
      }
    });
  }

  Future<void> queryVideoTags() async {
    final result = await UserHttp.videoTags(bvid: bvid, cid: cid.value);
    videoTags.value = result.dataOrNull;
  }

  bool _savingLater = false;

  Future<void> viewLater() async {
    if (_savingLater || isClosed) return;
    final account = Accounts.main;
    final video = bvid;
    final removing = hasLater.value;
    _savingLater = true;
    try {
      final res = await (removing
          ? UserHttp.toViewDel(
              aids: IdUtils.bv2av(video).toString(),
              account: account,
            )
          : UserHttp.toViewLater(bvid: video, account: account));
      if (isClosed || bvid != video || !identical(account, Accounts.main)) {
        return;
      }
      if (res.isSuccess) {
        hasLater.value = !removing;
        SmartDialog.showToast(removing ? '已移除稍后再看' : '已添加到稍后再看');
      } else {
        res.toast();
      }
    } finally {
      _savingLater = false;
    }
  }
}

mixin FavMixin on TripleMixin {
  Set? favIds;
  int? quickFavId;
  late final enableQuickFav = Pref.enableQuickFav;
  final Rx<FavFolderData> favFolderData = FavFolderData().obs;
  Account? _favAccount;
  int _favQueryVersion = 0;
  bool _savingFav = false;

  (Object, int) get getFavRidType;

  Future<LoadingState<FavFolderData>> queryVideoInFolder({
    Account? account,
  }) async {
    account ??= Accounts.main;
    final version = ++_favQueryVersion;
    quickFavId = null;
    favIds = null;
    final (rid, type) = getFavRidType;
    final res = await FavHttp.videoInFolder(
      account: account,
      mid: account.mid,
      rid: rid,
      type: type,
    );
    if (isClosed ||
        !identical(account, Accounts.main) ||
        getFavRidType != (rid, type) ||
        version != _favQueryVersion) {
      return const Error('收藏夹或账号已更新，请重新打开');
    }
    if (res case Success(:final response)) {
      _favAccount = account;
      favFolderData.value = response;
      favIds = response.list
          ?.where((item) => item.favState == 1)
          .map((item) => item.id)
          .toSet();
    }
    return res;
  }

  int? get favFolderId {
    if (this.quickFavId != null) {
      return this.quickFavId!;
    }
    final quickFavId = Pref.quickFavId;
    final list = favFolderData.value.list;
    if (list == null || list.isEmpty) return null;
    if (quickFavId != null) {
      final folderInfo = list.firstWhereOrNull((e) => e.id == quickFavId);
      if (folderInfo != null) {
        return this.quickFavId = quickFavId;
      } else {
        GStorage.setting.delete(SettingBoxKey.quickFavId).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          logger.w(
            '清除失效默认收藏夹失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
        });
      }
    }
    return this.quickFavId = list.first.id;
  }

  // 收藏
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    // 快速收藏 &
    // 点按 收藏至默认文件夹
    // 长按选择文件夹
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void updateFavCount(int count);

  Future<void> actionFavVideo({bool isQuick = false}) async {
    if (_savingFav || isClosed) return;
    final account = Accounts.main;
    final target = getFavRidType;
    bool current() =>
        !isClosed &&
        identical(account, Accounts.main) &&
        getFavRidType == target;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    _savingFav = true;
    var showingLoading = false;
    try {
      final (rid, type) = target;
      // 收藏至默认文件夹
      if (isQuick) {
        SmartDialog.showLoading(msg: '请求中');
        showingLoading = true;
        final res = await queryVideoInFolder(account: account);
        if (!current()) return;
        if (res.isSuccess) {
          final hasFav = this.hasFav.value;
          final folder = hasFav ? null : favFolderId;
          if (!hasFav && folder == null) {
            SmartDialog.showToast('暂无可用收藏夹，请先创建');
            return;
          }
          final result = hasFav
              ? await FavHttp.unfavAll(account: account, rid: rid, type: type)
              : await FavHttp.favVideo(
                  account: account,
                  resources: '$rid:$type',
                  addIds: folder.toString(),
                );
          if (!current()) return;
          if (result.isSuccess) {
            updateFavCount(hasFav ? -1 : 1);
            this.hasFav.toggle();
            SmartDialog.showToast('${hasFav ? '取消' : ''}收藏成功');
          } else {
            result.toast();
          }
        } else {
          res.toast();
        }
        return;
      }

      final folders = favFolderData.value.list;
      if (!identical(account, _favAccount) ||
          folders == null ||
          favIds == null) {
        SmartDialog.showToast('收藏夹或账号已更新，请重新打开');
        return;
      }
      final addMediaIdsNew = <int>[];
      final delMediaIdsNew = <int>[];
      for (final i in folders) {
        bool isFaved = favIds?.contains(i.id) == true;
        if (i.favState == 1) {
          if (!isFaved) {
            addMediaIdsNew.add(i.id);
          }
        } else {
          if (isFaved) {
            delMediaIdsNew.add(i.id);
          }
        }
      }
      if (addMediaIdsNew.isEmpty && delMediaIdsNew.isEmpty) {
        Get.back();
        return;
      }
      SmartDialog.showLoading(msg: '请求中');
      showingLoading = true;
      final result = await FavHttp.favVideo(
        account: account,
        resources: '$rid:$type',
        addIds: addMediaIdsNew.join(','),
        delIds: delMediaIdsNew.join(','),
      );
      if (!current()) return;
      if (result.isSuccess) {
        Get.back();
        final newVal =
            addMediaIdsNew.isNotEmpty ||
            favIds?.length != delMediaIdsNew.length;
        if (hasFav.value != newVal) {
          updateFavCount(newVal ? 1 : -1);
          hasFav.value = newVal;
        }
        SmartDialog.showToast('${newVal ? '' : '取消'}收藏成功');
      } else {
        result.toast();
      }
    } catch (error, stackTrace) {
      logger.w('收藏操作未完成', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('操作结果待确认，请核对收藏夹后再操作');
    } finally {
      _savingFav = false;
      if (showingLoading) {
        // 弹层关闭等待 Flutter 帧，不能延长实际写入的 Future 或覆盖其结果。
        unawaited(
          SmartDialog.dismiss(status: SmartStatus.loading).catchError(
            (Object error, StackTrace stackTrace) {
              logger.w(
                '关闭收藏加载提示失败',
                error: error.runtimeType,
                stackTrace: stackTrace,
              );
            },
          ),
        );
      }
    }
  }
}
