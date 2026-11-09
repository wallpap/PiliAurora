import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply;
import 'package:pili_aurora/http/music.dart';
import 'package:pili_aurora/models/remote/music/bgm_detail.dart';
import 'package:pili_aurora/pages/common/dyn/common_dyn_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class MusicDetailController extends CommonDynController {
  MusicDetailController({String? musicId})
    : musicId = musicId ?? Get.parameters['musicId'] ?? '';

  int _oid = 0;
  int _replyType = 47;
  @override
  int get oid => _oid;
  @override
  int get replyType => _replyType;

  bool get canComment => oid > 0;
  int _detailsVersion = 0;
  Account? _detailsAccount;
  final _updatingWish = false.obs;
  bool get updatingWish => _updatingWish.value;

  @override
  dynamic get sourceId => oid.toString();

  final infoState = LoadingState<MusicDetail>.loading().obs;

  final String musicId;

  @override
  // 评论同时属于当前账号和详情快照，刷新为无评论详情时也要废弃旧评论。
  Object get queryContext => identical(_detailsAccount, Accounts.main)
      ? infoState.value.dataOrNull ?? Accounts.main
      : Accounts.main;

  @override
  String get emptyReplyMessage =>
      canComment ? super.emptyReplyMessage : '该音乐暂不支持评论';

  @override
  Future<LoadingState<MainListReply>> customGetData() async =>
      canComment ? await super.customGetData() : const Error('该音乐暂不支持评论');

  String get shareUrl =>
      'https://music.bilibili.com/h5/music-detail?music_id=$musicId';

  @override
  void onInit() {
    super.onInit();
    getMusicDetail();
  }

  Future<void> getMusicDetail() async {
    if (isClosed) return;
    final version = ++_detailsVersion;
    final account = Accounts.main;
    if (infoState.value is Error) infoState.value = LoadingState.loading();
    bool owned() => !isClosed && version == _detailsVersion;
    void retireAccount() {
      infoState.value = const Error('账号已切换，请刷新音乐详情');
      loadingState.value = const Error('账号已切换，请刷新评论');
    }

    final res = await MusicHttp.bgmDetail(musicId, account: account);
    if (!owned()) return;
    if (!identical(account, Accounts.main)) {
      retireAccount();
      return;
    }
    infoState.value = res;
    if (res case Success(:final response)) {
      _detailsAccount = account;
      final comment = response.musicComment;
      _oid = comment?.oid ?? 0;
      _replyType = comment?.pageType ?? 47;
      count.value = comment?.nums ?? -1;
      if (canComment) {
        try {
          await super.onRefresh();
        } catch (error, stackTrace) {
          if (!isClosed &&
              version == _detailsVersion &&
              identical(account, Accounts.main)) {
            loadingState.value = Error.fromException(error, stackTrace);
          }
        }
        if (owned() && !identical(account, Accounts.main)) retireAccount();
      } else {
        count.value = 0;
        isEnd = true;
        loadingState.value = const Success([]);
      }
    }
  }

  @override
  Future<void> onRefresh() => getMusicDetail();

  Future<void> toggleWish(MusicDetail item) async {
    if (updatingWish ||
        isClosed ||
        !identical(infoState.value.dataOrNull, item)) {
      return;
    }
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('请先登录');
      return;
    }
    if (!identical(_detailsAccount, account)) {
      SmartDialog.showToast('账号已更新，请刷新音乐详情后再操作');
      return;
    }
    final version = _detailsVersion;
    bool current() =>
        !isClosed &&
        version == _detailsVersion &&
        identical(account, Accounts.main) &&
        identical(infoState.value.dataOrNull, item);
    _updatingWish.value = true;
    try {
      final hasLike = item.wishListen ?? false;
      final result = await MusicHttp.wishUpdate(
        musicId,
        hasLike,
        account: account,
      );
      if (!current()) return;
      if (result.isSuccess) {
        final count = item.wishCount;
        if (count != null) {
          item.wishCount = hasLike ? (count > 0 ? count - 1 : 0) : count + 1;
        }
        item.wishListen = !hasLike;
        infoState.refresh();
      } else {
        result.toast();
      }
    } catch (error, stackTrace) {
      final failure = Error.fromException(error, stackTrace);
      if (current()) {
        UnknownResult(
          cause: failure.cause,
          stackTrace: failure.stackTrace,
        ).toast();
      }
    } finally {
      _updatingWish.value = false;
    }
  }

  @override
  void onClose() {
    _detailsVersion++;
    super.onClose();
  }
}
