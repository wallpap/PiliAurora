import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart' show Options;

import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show ReloadMixin;
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/remote/member_card_info/data.dart';
import 'package:pili_aurora/models/remote/relation/data.dart';
import 'package:pili_aurora/models/remote/video/video_ai_conclusion/model_result.dart';
import 'package:pili_aurora/models/remote/video/video_detail/dimension.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/models/remote/video/video_detail/section.dart';
import 'package:pili_aurora/models/remote/video/video_detail/staff.dart';
import 'package:pili_aurora/models/remote/video/video_detail/stat_detail.dart';
import 'package:pili_aurora/models/remote/video/video_detail/ugc_season.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/dynamics_repost/view.dart';
import 'package:pili_aurora/pages/video/related/controller.dart';
import 'package:pili_aurora/pages/video/reply/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class UgcIntroController extends CommonIntroController with ReloadMixin {
  late final RxBool expand;
  final RxBool status = true.obs;

  // up主粉丝数
  final Rx<MemberCardInfoData> userStat = MemberCardInfoData().obs;
  // 关注状态 默认未关注
  late final Rx<RelationData> followStatus = Rx(RelationData());
  late final RxMap staffRelations = {}.obs;

  // 是否点踩
  final RxBool hasDislike = false.obs;

  late final showArgueMsg = Pref.showArgueMsg;
  late final enableAi = Pref.enableAi;
  late final horizontalMemberPage = Pref.horizontalMemberPage;

  AiConclusionResult? aiConclusionResult;

  late final Map<int?, bool> seasonFavState = {};

  @override
  void onInit() {
    super.onInit();
    final alwaysExpandIntroPanel = Pref.alwaysExpandIntroPanel;
    expand = RxBool(alwaysExpandIntroPanel);
    if (!alwaysExpandIntroPanel && Pref.expandIntroPanelH) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!expand.value && !DeviceUtils.size.isPortrait) {
          expand.toggle();
        }
      });
    }
    videoDetail.value.title = Get.arguments['title'] ?? '';
  }

  // 获取视频简介&分p
  int _introQuery = 0;
  @override
  Future<void> queryVideoIntro() async {
    if (isClosed) return;
    final version = ++_introQuery;
    final video = bvid;
    final account = Accounts.heartbeat;
    queryVideoTags();
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (isClosed ||
        version != _introQuery ||
        bvid != video ||
        !identical(account, Accounts.heartbeat)) {
      return;
    }
    if (res case Success(:final response)) {
      if (response.redirectUrl != null &&
          videoDetailCtr.epId == null &&
          videoDetailCtr.seasonId == null) {
        if (!isClosed) {
          PageUtils.viewPgcFromUri(response.redirectUrl!, off: true);
        }
        return;
      }
      videoPlayerServiceHandler?.onVideoDetailChange(
        response,
        cid.value,
        heroTag,
      );
      if (videoDetail.value.ugcSeason?.id == response.ugcSeason?.id) {
        // keep reversed season
        response.ugcSeason = videoDetail.value.ugcSeason;
      }
      if (videoDetail.value.cid == response.cid) {
        // keep reversed pages
        response
          ..pages = videoDetail.value.pages
          ..isPageReversed = videoDetail.value.isPageReversed;
      }
      videoDetail.value = response;
      status.value = true;
      try {
        if (videoDetailCtr.cover.value.isEmpty ||
            (videoDetailCtr.videoUrl.isNullOrEmpty &&
                !videoDetailCtr.isQuerying)) {
          videoDetailCtr.cover.value = response.pic ?? '';
        }
        if (videoDetailCtr.showReply) {
          try {
            Get.find<VideoReplyController>(tag: heroTag).count.value =
                response.stat?.reply ?? 0;
          } catch (_) {}
        }
      } catch (_) {}
      final pages = videoDetail.value.pages;
      if (pages != null && pages.isNotEmpty && cid.value == 0) {
        cid.value = pages.first.cid!;
      }
      queryUserStat(response.staff);
    } else {
      res.toast();
      status.value = false;
    }

    if (isLogin) {
      queryAllStatus();
      queryFollowStatus();
    }
  }

  // 获取up主粉丝数
  int _statQuery = 0;
  Future<void> queryUserStat(List<Staff>? staff) async {
    final version = ++_statQuery;
    final video = bvid;
    final account = Accounts.main;
    bool current() =>
        !isClosed &&
        version == _statQuery &&
        video == bvid &&
        identical(account, Accounts.main);
    if (staff != null && staff.isNotEmpty) {
      final res = await Request().requestApi<Map<String, dynamic>>(
        Api.relations,
        kind: ApiCallKind.query,
        options: Options(extra: {'account': account}),
        decode: (body) => body['data'] as Map<String, dynamic>,
        queryParameters: {'fids': staff.map((item) => item.mid).join(',')},
      );
      if (res case Success(:final response) when current()) {
        staffRelations.assignAll({'status': true, ...response});
      }
    } else {
      final mid = videoDetail.value.owner?.mid;
      if (mid == null) {
        return;
      }
      final res = await MemberHttp.memberCardInfo(
        mid: mid,
        account: account,
      );
      if (res case Success(:final response) when current()) {
        userStat.value = response;
      }
    }
  }

  int _relationQuery = 0;

  Future<void> queryAllStatus() async {
    if (interactionBusy || isClosed) return;
    final account = Accounts.main;
    final target = interactionTarget;
    final revision = interactionRevision;
    final query = ++_relationQuery;
    final result = await VideoHttp.videoRelation(bvid: bvid, account: account);
    if (!ownsInteraction(account, target) ||
        revision != interactionRevision ||
        query != _relationQuery) {
      return;
    }
    if (result case Success(:final response)) {
      final stat = getStat();
      if (response.like) stat?.like = max(1, stat.like);
      if (response.favorite) stat?.favorite = max(1, stat.favorite);
      hasLike.value = response.like;
      hasDislike.value = response.dislike;
      coinNum.value = response.coin;
      hasFav.value = response.favorite;
    }
  }

  // 一键三连：逐项消费回执，部分成功不能提示完整成功。
  @override
  Future<void> actionTriple() => runInteraction((account, current) async {
    feedBack();
    if (hasTriple) {
      SmartDialog.showToast('已三连');
      return;
    }
    final result = await VideoHttp.ugcTriple(bvid: bvid, account: account);
    if (result case Success(:final response)) {
      final paid = response.coin ? response.multiply : 0;
      if (identical(account, Accounts.main)) GlobalData().afterCoin(paid);
      if (!current()) return;
      final stat = getStat();
      if (response.like && !hasLike.value) {
        stat?.like++;
        hasLike.value = true;
        hasDislike.value = false;
      }
      if (paid > 0) {
        stat?.coin += paid;
        coinNum.value += paid;
      }
      if (response.fav && !hasFav.value) {
        stat?.favorite++;
        hasFav.value = true;
      }
      SmartDialog.showToast(hasTriple ? '三连成功' : '三连未全部完成，请核对点赞、投币和收藏状态');
    } else if (current()) {
      result.toast();
    }
  });

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
      if (newVal) hasDislike.value = false;
    } else {
      result.toast();
    }
  });

  Future<void> actionDislikeVideo() => runInteraction((account, current) async {
    final newVal = !hasDislike.value;
    final result = await VideoHttp.dislikeVideo(
      bvid: bvid,
      type: newVal,
      account: account,
    );
    if (!current()) return;
    if (result.isSuccess) {
      SmartDialog.showToast(newVal ? '点踩成功' : '取消踩');
      hasDislike.value = newVal;
      if (newVal && hasLike.value) {
        getStat()?.like--;
        hasLike.value = false;
      }
    } else {
      result.toast();
    }
  });

  @override
  int get copyright => videoDetail.value.copyright ?? 1;

  @override
  (Object, int) get getFavRidType => (IdUtils.bv2av(bvid), 2);

  @override
  StatDetail? getStat() => videoDetail.value.stat;

  // 分享视频
  @override
  void actionShareVideo(BuildContext context) {
    final account = Accounts.main;
    bool ownsAccount() =>
        context.mounted && !isClosed && identical(account, Accounts.main);
    final videoDetail = this.videoDetail.value;
    final cid = this.cid.value;
    final partIndex = videoDetail.pages?.indexWhere((e) => e.cid == cid);
    final addIndex = partIndex != null && partIndex > 0;
    final playedTimePos = videoDetailCtr.playedTimePos(addIndex);
    final videoUrl =
        '${HttpString.baseUrl}/video/$bvid/${addIndex ? '?p=${partIndex + 1}' : ''}';
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          ListTile(
            dense: true,
            title: const Text(
              '复制链接',
              style: TextStyle(fontSize: 14),
            ),
            onTap: () {
              Get.back();
              Utils.copyText(videoUrl);
            },
            trailing: playedTimePos.isNotEmpty
                ? iconButton(
                    tooltip: '精确分享',
                    icon: const Icon(Icons.timer_outlined),
                    onPressed: () {
                      Get.back();
                      Utils.copyText('$videoUrl$playedTimePos');
                    },
                  )
                : null,
          ),
          ListTile(
            dense: true,
            title: const Text(
              '其它app打开',
              style: TextStyle(fontSize: 14),
            ),
            onTap: () {
              Get.back();
              PiliAndroidHelper.openUrl(videoUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            ListTile(
              dense: true,
              title: const Text(
                '分享视频',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                ShareUtils.shareText(
                  '${videoDetail.title} '
                  'UP主: ${videoDetail.owner!.name!}'
                  ' - $videoUrl',
                );
              },
            ),
          if (isLogin)
            ListTile(
              dense: true,
              title: const Text(
                '分享至动态',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                if (!ownsAccount()) return;
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (context) => RepostPanel(
                    rid: videoDetail.aid,
                    dynType: 8,
                    pic: videoDetail.pic,
                    title: videoDetail.title,
                    uname: videoDetail.owner?.name,
                  ),
                );
              },
            ),
          if (isLogin)
            ListTile(
              dense: true,
              title: const Text(
                '分享至消息',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () async {
                Get.back();
                if (!ownsAccount()) return;
                try {
                  await PageUtils.pmShare(
                    context,
                    content: {
                      "id": videoDetail.aid!.toString(),
                      "title": videoDetail.title!,
                      "headline": videoDetail.title!,
                      "source": 5,
                      "thumb": videoDetail.pic!,
                      "author": videoDetail.owner!.name!,
                      "author_id": videoDetail.owner!.mid!.toString(),
                    },
                  );
                } catch (error, stack) {
                  logger.w(
                    '打开视频分享失败',
                    error: error.runtimeType,
                    stackTrace: stack,
                  );
                  if (ownsAccount()) SmartDialog.showToast('无法打开分享面板，请重试');
                }
              },
            ),
        ],
      ),
    );
  }

  // 查询关注状态
  Future<void> queryFollowStatus() async {
    final videoDetail = this.videoDetail.value;
    if (videoDetail.owner == null || videoDetail.staff?.isNotEmpty == true) {
      return;
    }
    final res = await UserHttp.userRelation(videoDetail.owner!.mid!);
    if (res case Success(:final response)) {
      if (response.special == 1) response.attribute = -10;
      followStatus.value = response;
    }
  }

  // 关注/取关up
  Future<void> actionRelationMod(BuildContext context) async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final videoDetail = this.videoDetail.value;
    if (videoDetail.staff?.isNotEmpty == true) {
      return;
    }
    int? mid = videoDetail.owner?.mid;
    if (mid == null) {
      return;
    }
    int attr = followStatus.value.attribute ?? 0;
    if (attr == 128) {
      final res = await VideoHttp.relationMod(
        mid: mid,
        act: 6,
        reSrc: 11,
      );
      if (res.isSuccess) {
        followStatus
          ..value.attribute = 0
          ..refresh();
      }
      return;
    } else {
      RequestUtils.actionRelationMod(
        context: context,
        mid: mid,
        isFollow: attr != 0,
        followStatus: followStatus.value,
        afterMod: (attribute) {
          followStatus
            ..value.attribute = attribute
            ..refresh();
          Timer(const Duration(milliseconds: 500), queryFollowStatus);
        },
      );
    }
  }

  // 修改分P或番剧分集
  int _episodeChange = 0;

  Future<bool> onChangeEpisode(
    BaseEpisodeItem episode, {
    bool isStein = false,
  }) async {
    if (isClosed) return false;
    final version = ++_episodeChange;
    final account = Accounts.heartbeat;
    final mainAccount = Accounts.main;
    final source = (bvid, cid.value);
    final videoSource = (videoDetailCtr.bvid, videoDetailCtr.cid.value);
    final ownsPlayback = videoDetailCtr.playbackOwner.guard();
    bool current() =>
        !isClosed &&
        version == _episodeChange &&
        identical(account, Accounts.heartbeat) &&
        identical(mainAccount, Accounts.main) &&
        source == (bvid, cid.value) &&
        videoSource == (videoDetailCtr.bvid, videoDetailCtr.cid.value) &&
        ownsPlayback();
    try {
      if (!current()) return false;
      final String bvid = episode.bvid ?? this.bvid;
      final int aid = episode.aid ?? IdUtils.bv2av(bvid);
      int? cid = episode.cid;
      final String? cover = episode.cover;
      Dimension? dimension;
      if (cid == null || cid <= 0) {
        final result = await SearchHttp.pageWithDimension(
          account: account,
          aid: aid,
          bvid: bvid,
        );
        if (!current()) return false;
        if (result is Error) {
          result.toast();
          return false;
        }
        cid = result.dataOrNull?.cid;
        dimension = result.dataOrNull?.dimension;
      }
      if (!current()) return false;
      if (cid == null || cid <= 0) {
        SmartDialog.showToast('该视频暂无可播放分 P');
        return false;
      }

      // 重新获取视频资源
      if (videoDetailCtr.isPlayAll) {
        if (videoDetailCtr.mediaList.indexWhere((item) => item.bvid == bvid) ==
            -1) {
          if (dimension == null && episode is EpisodeItem) {
            dimension = episode.page?.dimension;
          }
          PageUtils.toVideoPage(
            bvid: bvid,
            cid: cid,
            cover: cover,
            dimension: dimension,
            title: episode.title,
          );
          return false;
        }
      }

      videoDetailCtr
        ..inheritedSubtitleEnabled =
            Pref.inheritSubtitleState && bvid == this.bvid
            ? videoDetailCtr.vttSubtitlesIndex.value > 0
            : null
        ..plPlayerController.pause()
        ..makeHeartBeat()
        ..updateMediaListHistory(aid)
        ..onReset(isStein: isStein)
        ..bvid = bvid
        ..aid = aid
        ..cid.value = cid
        ..queryVideoUrl();

      if (this.bvid != bvid) {
        reload = true;
        aiConclusionResult = null;

        if (cover != null && cover.isNotEmpty) {
          videoDetailCtr.cover.value = cover;
        }

        // 重新请求相关视频
        if (videoDetailCtr.plPlayerController.showRelatedVideo) {
          try {
            Get.find<RelatedController>(tag: heroTag)
              ..bvid = bvid
              ..queryData();
          } catch (_) {}
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

        hasLater.value = videoDetailCtr.sourceType == SourceType.watchLater;
        this.bvid = bvid;
        queryVideoIntro();
      } else {
        if (episode is Part) {
          final videoDetail = this.videoDetail.value;
          videoPlayerServiceHandler?.onVideoDetailChange(
            episode,
            cid,
            heroTag,
            artist: videoDetail.owner?.name,
            cover: videoDetail.pic,
          );
        }
      }

      this.cid.value = cid;
      queryOnlineTotal();
      return true;
    } catch (e, stackTrace) {
      logger.w('切换视频分 P 失败', error: e.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('切换分 P 失败，请重试');
      return false;
    }
  }

  /// 播放上一个
  @override
  bool prevPlay([bool skipPart = false]) {
    final List<BaseEpisodeItem> episodes = <BaseEpisodeItem>[];
    bool isPart = false;

    final videoDetail = this.videoDetail.value;

    if (!skipPart && (videoDetail.pages?.length ?? 0) > 1) {
      isPart = true;
      episodes.addAll(videoDetail.pages!);
    } else if (videoDetailCtr.isPlayAll) {
      episodes.addAll(videoDetailCtr.mediaList);
    } else if (videoDetail.ugcSeason != null) {
      final UgcSeason ugcSeason = videoDetail.ugcSeason!;
      final List<SectionItem> sections = ugcSeason.sections!;
      for (int i = 0; i < sections.length; i++) {
        final List<EpisodeItem> episodesList = sections[i].episodes!;
        episodes.addAll(episodesList);
      }
    }

    final int currentIndex = episodes.indexWhere(
      (e) =>
          e.cid ==
          (skipPart
              ? videoDetail.isPageReversed
                    ? videoDetail.pages!.last.cid
                    : videoDetail.pages!.first.cid
              : this.cid.value),
    );

    int prevIndex = currentIndex - 1;
    final PlayRepeat playRepeat = videoDetailCtr.plPlayerController.playRepeat;

    // 列表循环
    if (prevIndex < 0) {
      if (isPart &&
          (videoDetailCtr.isPlayAll || videoDetail.ugcSeason != null)) {
        return prevPlay(true);
      }
      if (playRepeat == PlayRepeat.listCycle) {
        prevIndex = episodes.length - 1;
      } else {
        return false;
      }
    }

    int? cid = episodes[prevIndex].cid;
    while (cid == null) {
      prevIndex--;
      if (prevIndex < 0) {
        return false;
      }
      cid = episodes[prevIndex].cid;
    }

    if (cid != this.cid.value) {
      onChangeEpisode(episodes[prevIndex]);
      return true;
    } else {
      return false;
    }
  }

  /// 列表循环或者顺序播放时，自动播放下一个
  @override
  bool nextPlay([bool skipPart = false]) {
    try {
      final List<BaseEpisodeItem> episodes = <BaseEpisodeItem>[];
      bool isPart = false;
      final videoDetail = this.videoDetail.value;

      // part -> playall -> season
      if (!skipPart && (videoDetail.pages?.length ?? 0) > 1) {
        isPart = true;
        final List<Part> pages = videoDetail.pages!;
        episodes.addAll(pages);
      } else if (videoDetailCtr.isPlayAll) {
        episodes.addAll(videoDetailCtr.mediaList);
      } else if (videoDetail.ugcSeason != null) {
        final UgcSeason ugcSeason = videoDetail.ugcSeason!;
        final List<SectionItem> sections = ugcSeason.sections!;
        for (int i = 0; i < sections.length; i++) {
          final List<EpisodeItem> episodesList = sections[i].episodes!;
          episodes.addAll(episodesList);
        }
      }

      final PlayRepeat playRepeat =
          videoDetailCtr.plPlayerController.playRepeat;

      if (episodes.isEmpty) {
        if (playRepeat == PlayRepeat.listCycle) {
          videoDetailCtr.plPlayerController.play(repeat: true);
          return true;
        }
        if (playRepeat == PlayRepeat.autoPlayRelated &&
            videoDetailCtr.plPlayerController.showRelatedVideo) {
          return playRelated();
        }
        return false;
      }

      final int currentIndex = episodes.indexWhere(
        (e) =>
            e.cid ==
            (skipPart
                ? videoDetail.isPageReversed
                      ? videoDetail.pages!.last.cid
                      : videoDetail.pages!.first.cid
                : this.cid.value),
      );

      int nextIndex = currentIndex + 1;

      if (!isPart &&
          videoDetailCtr.isPlayAll &&
          currentIndex == episodes.length - 2) {
        videoDetailCtr.getMediaList();
      }

      // 列表循环
      if (nextIndex >= episodes.length) {
        if (isPart &&
            (videoDetailCtr.isPlayAll || videoDetail.ugcSeason != null)) {
          return nextPlay(true);
        }

        if (playRepeat == PlayRepeat.listCycle) {
          nextIndex = 0;
        } else if (playRepeat == PlayRepeat.autoPlayRelated &&
            videoDetailCtr.plPlayerController.showRelatedVideo) {
          return playRelated();
        } else {
          return false;
        }
      }

      int? cid = episodes[nextIndex].cid;
      while (cid == null) {
        nextIndex++;
        if (nextIndex >= episodes.length) {
          return false;
        }
        cid = episodes[nextIndex].cid;
      }

      if (cid != this.cid.value) {
        onChangeEpisode(episodes[nextIndex]);
        return true;
      } else {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  bool playRelated() {
    RelatedController relatedCtr;
    if (Get.isRegistered<RelatedController>(tag: heroTag)) {
      relatedCtr = Get.find<RelatedController>(tag: heroTag);
    } else {
      relatedCtr = Get.put(RelatedController(autoQuery: false), tag: heroTag)
        ..queryData().whenComplete(playRelated);
      return false;
    }

    if (relatedCtr.loadingState.value case Success(:final response)) {
      final firstItem = response?.firstOrNull;
      if (firstItem == null) {
        SmartDialog.showToast('暂无相关视频，停止连播');
        return false;
      }
      onChangeEpisode(
        BaseEpisodeItem(
          aid: firstItem.aid,
          bvid: firstItem.bvid,
          cid: firstItem.cid,
          cover: firstItem.cover,
        ),
      );
      return true;
    }

    return false;
  }

  // ai总结
  static Future<AiConclusionResult?> getAiConclusion(
    String bvid,
    int cid,
    int? mid,
  ) async {
    if (!Accounts.heartbeat.isLogin) {
      SmartDialog.showToast("账号未登录");
      return null;
    }
    SmartDialog.showLoading(msg: '正在获取AI总结');
    final account = Accounts.heartbeat;
    final res = await VideoHttp.aiConclusion(
      bvid: bvid,
      cid: cid,
      upMid: mid,
    );
    unawaited(
      SmartDialog.dismiss(status: .loading)
          .catchError((Object error, StackTrace stackTrace) {
            logger.w(
              '关闭 AI 总结加载提示失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
          }),
    );
    if (!identical(account, Accounts.heartbeat)) return null;
    if (res case Success(:final response)) {
      return response.modelResult;
    } else if (res is Error && res.code == 1) {
      SmartDialog.showToast("AI处理中，请稍后再试");
    } else {
      res.toast();
    }
    return null;
  }

  Future<void> aiConclusion() async {
    final video = bvid;
    final part = cid.value;
    final account = Accounts.heartbeat;
    final result = await getAiConclusion(
      bvid,
      cid.value,
      videoDetail.value.owner?.mid,
    );
    if (!isClosed &&
        video == bvid &&
        part == cid.value &&
        identical(account, Accounts.heartbeat)) {
      aiConclusionResult = result;
    }
  }
}
