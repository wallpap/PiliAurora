import 'dart:async';
import 'dart:math' show max;

import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/pgc/season_follow_status.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart'
    hide EpisodeItem;
import 'package:pili_aurora/models/remote/video/video_detail/stat_detail.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/dynamics_repost/view.dart';
import 'package:pili_aurora/pages/video/reply/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

enum _FollowAction { add, remove, update }

class PgcIntroController extends CommonIntroController {
  int? seasonId;
  int? epId;

  late final String pgcType = pgcItem.type == 1 || pgcItem.type == 4
      ? '追番'
      : '追剧';

  late final bool isPgc;
  late final PgcInfoModel pgcItem;
  late List<EpisodeItem> _playbackEpisodes;

  @override
  (Object, int) get getFavRidType => (epId!, 24);

  @override
  StatDetail? getStat() => pgcItem.stat;

  final followState = LoadingState<SeasonFollowStatus>.loading().obs;
  final followBusy = false.obs;
  int _followQueryVersion = 0;
  int _followOperation = 0;
  var _followAccount = Accounts.main;
  int? get followSeasonId => pgcItem.seasonId ?? seasonId;
  late final RxBool isFav = (pgcItem.userStatus?.favored == 1).obs;

  @override
  void onInit() {
    final args = Get.arguments;
    seasonId = args['seasonId'];
    epId = args['epId'];
    isPgc = args['videoType'] == VideoType.pgc;
    pgcItem = args['pgcItem'];
    _playbackEpisodes = pgcItem.episodes ?? <EpisodeItem>[];

    super.onInit();
    Accounts.mainChanges.addListener(_onFollowAccountChanged);

    if (isPgc) {
      queryIsFollowed();
      if (isLogin && epId != null) queryPgcLikeCoinFav();
      queryVideoTags();
    }
  }

  void setPlaybackEpisodes(List<EpisodeItem> episodes) {
    if (episodes.isNotEmpty) {
      _playbackEpisodes = episodes;
    }
  }

  @override
  Object get interactionTarget => (bvid, epId);

  int _relationQuery = 0;

  // 获取点赞/投币/收藏状态
  Future<void> queryPgcLikeCoinFav() async {
    if (interactionBusy || isClosed || epId == null) return;
    final account = Accounts.main;
    final target = interactionTarget;
    final revision = interactionRevision;
    final query = ++_relationQuery;
    final result = await VideoHttp.pgcLikeCoinFav(
      epId: epId!,
      account: account,
    );
    if (!ownsInteraction(account, target) ||
        revision != interactionRevision ||
        query != _relationQuery) {
      return;
    }
    if (result case Success(:final response)) {
      final hasLike = response.like == 1;
      final hasFav = response.favorite == 1;
      final stat = getStat();
      if (hasLike) stat?.like = max(1, stat.like);
      if (hasFav) stat?.favorite = max(1, stat.favorite);
      this.hasLike.value = hasLike;
      coinNum.value = response.coinNumber;
      this.hasFav.value = hasFav;
    } else {
      result.toast();
    }
  }

  // （取消）点赞
  @override
  Future<void> actionLikeVideo() => runInteraction((account, current) async {
    final newVal = !hasLike.value;
    final result = await VideoHttp.likeVideo(
      bvid: bvid,
      type: newVal,
      account: account,
    );
    if (!current()) return;
    if (result case Success(:final response)) {
      SmartDialog.showToast(newVal ? response ?? '点赞成功' : '取消赞');
      getStat()?.like += newVal ? 1 : -1;
      hasLike.value = newVal;
    } else {
      result.toast();
    }
  });

  @override
  int get copyright => 1;

  // 分享视频
  @override
  void actionShareVideo(BuildContext context) {
    final episodes = <EpisodeItem>[
      ...?pgcItem.episodes,
      for (final section in pgcItem.section ?? const []) ...?section.episodes,
    ];
    bool isCurrentEpisode(EpisodeItem item) => (item.epId ?? item.id) == epId;

    String videoUrl =
        '${HttpString.baseUrl}/bangumi/play/ep$epId${videoDetailCtr.playedTimePos(false)}';
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              Utils.copyText(videoUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              PiliAndroidHelper.openUrl(videoUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
                final item = episodes.firstWhereOrNull(isCurrentEpisode);
                Get.back();
                ShareUtils.shareText(
                  '${pgcItem.title}${item != null ? ' ${item.showTitle}' : ''}'
                  ' - $videoUrl',
                );
              },
            ),
          if (isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                final item = episodes.firstWhereOrNull(isCurrentEpisode);
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (context) => RepostPanel(
                    rid: epId,
                    /*
                    1：番剧 // 4097
                    2：电影 // 4098
                    3：纪录片 // 4101
                    4：国创 // 4100
                    5：电视剧 // 4099
                    6：漫画
                    7：综艺 // 4099
                  */
                    dynType: switch (pgcItem.type) {
                      1 => 4097,
                      2 => 4098,
                      3 => 4101,
                      4 => 4100,
                      5 || 7 => 4099,
                      _ => -1,
                    },
                    pic: pgcItem.cover,
                    title:
                        '${pgcItem.title}${item != null ? '\n${item.showTitle}' : ''}',
                    uname: '',
                  ),
                );
              },
            ),
          if (isLogin)
            DialogOption(
              child: const Text(
                '分享至消息',
                style: TextStyle(fontSize: 14),
              ),
              onPressed: () {
                Get.back();
                try {
                  final item = episodes.firstWhere(isCurrentEpisode);
                  final title =
                      item.shareCopy ??
                      '${pgcItem.title} ${item.showTitle ?? item.longTitle}';
                  PageUtils.pmShare(
                    context,
                    content: {
                      "id": epId!.toString(),
                      "title": title,
                      "url": item.shareUrl,
                      "headline": title,
                      "source": 16,
                      "thumb": item.cover,
                      "source_desc": switch (pgcItem.type) {
                        1 => '番剧',
                        2 => '电影',
                        3 => '纪录片',
                        4 => '国创',
                        5 => '电视剧',
                        6 => '漫画',
                        7 => '综艺',
                        _ => null,
                      },
                    },
                  );
                } catch (e) {
                  SmartDialog.showToast(e.toString());
                }
              },
            ),
        ],
      ),
    );
  }

  // 修改分P或番剧分集
  Future<bool> onChangeEpisode(BaseEpisodeItem episode) async {
    try {
      final int epId = episode.epId ?? episode.id!;
      final String bvid = episode.bvid ?? this.bvid;
      final int aid = episode.aid ?? IdUtils.bv2av(bvid);
      final int? cid =
          episode.cid ?? await SearchHttp.ab2c(aid: aid, bvid: bvid);
      if (cid == null) {
        return false;
      }
      final String? cover = episode.cover;

      // 重新获取视频资源
      this.epId = epId;
      this.bvid = bvid;

      videoDetailCtr
        ..plPlayerController.pause()
        ..makeHeartBeat()
        ..onReset()
        ..epId = epId
        ..bvid = bvid
        ..aid = aid
        ..cid.value = cid
        ..queryVideoUrl();
      if (cover != null && cover.isNotEmpty) {
        videoDetailCtr.cover.value = cover;
      }

      // 重新请求评论
      if (videoDetailCtr.showReply) {
        try {
          final replyCtr = Get.find<VideoReplyController>(tag: heroTag)
            ..aid = aid;
          if (replyCtr.loadingState.value is! Loading) {
            replyCtr.onReload();
          }
        } catch (_) {}
      }

      if (isPgc && isLogin) {
        queryPgcLikeCoinFav();
      }

      hasLater.value = videoDetailCtr.sourceType == SourceType.watchLater;
      this.cid.value = cid;
      queryOnlineTotal();
      queryVideoIntro(episode as EpisodeItem);
      return true;
    } catch (e, stackTrace) {
      logger.w('pgc onChangeEpisode: $e', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> pgcAdd() => _changeFollow(_FollowAction.add);
  Future<void> pgcDel() => _changeFollow(_FollowAction.remove);
  Future<void> pgcUpdate(int status) =>
      _changeFollow(_FollowAction.update, status: status);

  Future<void> _changeFollow(_FollowAction action, {int? status}) async {
    if (isClosed || followBusy.value) return;
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final target = followSeasonId;
    final operation = ++_followOperation;
    _followQueryVersion++;
    followBusy.value = true;
    try {
      final result = await switch (action) {
        _FollowAction.add => VideoHttp.pgcAdd(
          seasonId: target,
          account: account,
        ),
        _FollowAction.remove => VideoHttp.pgcDel(
          seasonId: target,
          account: account,
        ),
        _FollowAction.update => VideoHttp.pgcUpdate(
          seasonId: '$target',
          status: status!,
          account: account,
        ),
      };
      if (isClosed ||
          operation != _followOperation ||
          !identical(account, Accounts.main) ||
          target != followSeasonId) {
        return;
      }
      if (result case Success(:final response)) {
        followState.value = Success(
          SeasonFollowStatus(
            followed: action != _FollowAction.remove,
            status: action == _FollowAction.remove ? null : status ?? 2,
          ),
        );
        SmartDialog.showToast(response);
      } else {
        if (followState.value is Loading) followState.value = result as Error;
        result.toast();
      }
    } finally {
      if (operation == _followOperation) followBusy.value = false;
    }
  }

  @override
  bool prevPlay() {
    final episodes = _playbackEpisodes;
    if (episodes.isEmpty) return false;
    int currentIndex = episodes.indexWhere(
      (e) => e.cid == videoDetailCtr.cid.value,
    );
    int prevIndex = currentIndex - 1;
    PlayRepeat playRepeat = videoDetailCtr.plPlayerController.playRepeat;
    if (prevIndex < 0) {
      if (playRepeat == PlayRepeat.listCycle) {
        prevIndex = episodes.length - 1;
      } else {
        return false;
      }
    }
    onChangeEpisode(episodes[prevIndex]);
    return true;
  }

  /// 列表循环或者顺序播放时，自动播放下一个；自动连播时，播放相关视频
  @override
  bool nextPlay() {
    try {
      final episodes = _playbackEpisodes;
      if (episodes.isEmpty) return false;

      PlayRepeat playRepeat = videoDetailCtr.plPlayerController.playRepeat;

      int currentIndex = episodes.indexWhere(
        (e) => e.cid == videoDetailCtr.cid.value,
      );
      int nextIndex = currentIndex + 1;
      // 列表循环
      if (nextIndex >= episodes.length) {
        if (playRepeat == PlayRepeat.listCycle) {
          nextIndex = 0;
        } else {
          return false;
        }
      }
      onChangeEpisode(episodes[nextIndex]);
      return true;
    } catch (_) {
      return false;
    }
  }

  // 一键三连
  @override
  Future<void> actionTriple() => runInteraction((account, current) async {
    feedBack();
    if (hasTriple) {
      SmartDialog.showToast('已三连');
      return;
    }
    final episode = epId;
    if (episode == null) {
      SmartDialog.showToast('剧集信息不完整，请刷新后重试');
      return;
    }
    final previousCoins = coinNum.value;
    final result = await VideoHttp.pgcTriple(
      epId: episode,
      seasonId: seasonId,
      account: account,
    );
    if (result case Success(:final response)) {
      final paid = response.coin == 1
          ? max(0, response.coinNumber - previousCoins)
          : 0;
      if (identical(account, Accounts.main)) GlobalData().afterCoin(paid);
      if (!current()) return;
      final stat = getStat();
      if (response.like == 1 && !hasLike.value) {
        stat?.like++;
        hasLike.value = true;
      }
      if (response.coin == 1) {
        stat?.coin += paid;
        coinNum.value = response.coinNumber;
      }
      if (response.favorite == 1 && !hasFav.value) {
        stat?.favorite++;
        hasFav.value = true;
      }
      SmartDialog.showToast(hasTriple ? '三连成功' : '三连未全部完成，请核对点赞、投币和收藏状态');
    } else if (current()) {
      result.toast();
    }
  });

  void _onFollowAccountChanged() {
    if (identical(_followAccount, Accounts.main)) return;
    _followAccount = Accounts.main;
    _followOperation++;
    _followQueryVersion++;
    followBusy.value = false;
    followState.value = LoadingState.loading();
    if (isPgc) queryIsFollowed();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onFollowAccountChanged);
    _followQueryVersion++;
    _followOperation++;
    super.onClose();
  }

  Future<void> queryIsFollowed() async {
    if (isClosed || followBusy.value) return;
    final version = ++_followQueryVersion;
    final account = Accounts.main;
    _followAccount = account;
    final target = followSeasonId;
    followState.value = LoadingState.loading();
    if (!account.isLogin) {
      followState.value = const Success(SeasonFollowStatus(followed: false));
      return;
    }
    final result = await PgcHttp.seasonStatus(target, account: account);
    if (isClosed ||
        version != _followQueryVersion ||
        !identical(account, Accounts.main) ||
        target != followSeasonId) {
      return;
    }
    followState.value = result;
  }

  @override
  void queryVideoIntro([EpisodeItem? episode]) {
    episode ??= pgcItem.episodes!.firstWhere((e) => e.cid == cid.value);
    videoDetail
      ..value.title = episode.showTitle
      ..refresh();
    videoPlayerServiceHandler?.onVideoDetailChange(
      episode,
      cid.value,
      heroTag,
      artist: pgcItem.title,
    );
  }

  Future<void> onFavPugv(bool isFav) async {
    final res = isFav
        ? await FavHttp.delFavPugv(seasonId!)
        : await FavHttp.addFavPugv(seasonId!);
    if (res.isSuccess) {
      this.isFav.toggle();
      SmartDialog.showToast('${isFav ? '取消' : ''}收藏成功');
    } else {
      res.toast();
    }
  }
}
