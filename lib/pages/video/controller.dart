import 'dart:async';
import 'dart:math' show min;
import 'dart:ui';

import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:pili_aurora/common/widgets/scaffold/mini_scaffold.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:pili_aurora/grpc/dm.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/action_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/post_segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/media_list/media_list.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart'
    as ugc;
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/models/remote/video/video_pbp/data.dart';
import 'package:pili_aurora/models/remote/video/video_play_info/subtitle.dart';
import 'package:pili_aurora/models/remote/video/video_stein_edgeinfo/data.dart';
import 'package:pili_aurora/pages/audio/view.dart';
import 'package:pili_aurora/pages/common/publish/publish_route.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/pages/video/download_panel/view.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/pages/video/medialist/view.dart';
import 'package:pili_aurora/pages/video/playback_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/pages/video/note/view.dart';
import 'package:pili_aurora/pages/video/post_panel/view.dart';
import 'package:pili_aurora/pages/video/send_danmaku/view.dart';
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/models/heart_beat_type.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/connectivity_utils.dart';
import 'package:pili_aurora/utils/extension/context_ext.dart';
import 'package:pili_aurora/utils/extension/nested_scroll_ext.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show Options, CancelToken;
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' hide Subtitle;

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin, BlockMixin {
  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  @override
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  late bool isFileSource;
  late bool _mediaDesc = false;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  late PlayUrlModel data;
  final RxBool videoState = false.obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();
  AudioQuality? currentAudioQa;
  late VideoDecodeFormatType currentDecodeFormats;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool _autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<MiniScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;
  bool get removeSafeArea => plPlayerController.removeSafeArea;
  double get uiScale => plPlayerController.uiScale;

  late VideoItem firstVideo;
  NetworkSource? _networkSource;
  String? get videoUrl => _networkSource?.videoSource;
  String? get audioUrl =>
      _networkSource == null ? null : _networkSource!.audioSource ?? '';
  late final PlaybackOwner playbackOwner;
  Duration? defaultST;
  Duration? playedTime;
  String playedTimePos(bool hasParams) {
    final pos = playedTime?.inMilliseconds;
    if (pos != null && pos > 0) {
      return '${hasParams ? '&' : '?'}t=${pos / 1000}';
    }
    return '';
  }

  // 亮度
  double? brightness;

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late List<VideoDecodeFormatType> preferCodecs = Pref.preferCodecs;

  bool get showReply => isFileSource
      ? false
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  int? seasonCid;
  late final RxInt seasonIndex = 0.obs;

  PlayerStatus? playerStatus;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical;
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;
  ScrollController get scrollCtr => _scrollCtr ??= ScrollController();

  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    scrollKey.currentState?.refresh();
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();
      refreshPage();
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }

  void animToTop() {
    scrollKey.currentState?.animToTop();
  }

  bool _needAnimOnDimensionChanged(bool isVertical) {
    if (isFullScreen) {
      if (PlatformUtils.isMobile) {
        plPlayerController.changeOrientation(isVertical: isVertical);
      }
      return false;
    }
    return true;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _setVideoHeight() {
    try {
      var width = firstVideo.width;
      var height = firstVideo.height;
      if (width == null || height == null) {
        if (isUgc && !isFileSource) {
          final ugcIntroCtr = Get.find<UgcIntroController>(tag: heroTag);
          final cid = this.cid.value;
          final part = ugcIntroCtr.videoDetail.value.pages?.firstWhereOrNull(
            (e) => e.cid == cid,
          );
          if (part != null) {
            final dimension = part.dimension!;
            width = dimension.width!;
            height = dimension.height!;
          } else {
            return;
          }
        } else {
          return;
        }
      }
      final isVertical = height > width;
      if (_scrollCtr?.hasClients != true) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.isVertical.value != isVertical) {
          this.isVertical.value = isVertical;
          _needAnimOnDimensionChanged(isVertical);
        }
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            if (_needAnimOnDimensionChanged(isVertical)) {
              isExpanding = true;
              animationController.forward(
                from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
              );
            }
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = (maxVideoHeight - scrollCtr.offset)
                .toPrecision(2);
            double minVideoHeightPrecise = minVideoHeight.toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              this.videoHeight = minVideoHeight;
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(from: 1);
              }
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(
                  from: currentHeight / minVideoHeight,
                );
              }
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              if (_needAnimOnDimensionChanged(isVertical)) {
                isCollapsing = true;
                animationController.forward(
                  from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
                );
              }
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;
  void cacheLocalProgress() {
    if (plPlayerController.playerStatus.isCompleted) {
      watchProgress.put(cid.value.toString(), entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(cid.value.toString(), playedTime.inMilliseconds);
    }
  }

  void initFileSource(BiliDownloadEntryInfo entry, {bool isInit = true}) {
    this.entry = entry;
    firstVideo = VideoItem(
      id: entry.preferedVideoQuality,
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(cid.value.toString()) case final int progress?) {
      if (progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    _setVideoHeight();
  }

  @override
  void onInit() {
    super.onInit();
    playbackOwner = plPlayerController.attachPlaybackOwner();
    args = Get.arguments;
    videoType = args['videoType'];
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    } else if (args['pgcApi'] == true) {
      _actualVideoType = VideoType.pgc;
    }

    bvid = args['bvid'];
    aid = args['aid'];
    cid = RxInt(args['cid']);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    cover = RxString(args['cover'] ?? '');
    isVertical = RxBool(args['isVertical'] ?? false);

    sourceType = args['sourceType'] ?? SourceType.normal;
    isFileSource = sourceType == SourceType.file;
    isPlayAll = sourceType != SourceType.normal && !isFileSource;
    if (isFileSource) {
      initFileSource(args['entry']);
      if (args['progress'] case final int progress) {
        defaultST = Duration(milliseconds: progress);
      }
    } else if (isPlayAll) {
      watchLaterTitle = args['favTitle'];
      _mediaDesc = args['desc'];
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment ? 1 : 0,
    );
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                Get.find<UgcIntroController>(
                  tag: heroTag,
                ).onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            Get.find<UgcIntroController>(tag: heroTag).onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: bvid,
        count: args['count'],
        loadMoreMedia: getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: args['isContinuePlaying'] == true
            ? () => getMediaList(isLoadPrevious: true)
            : null,
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(
                    aids: item.aid.toString(),
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage
              ? Theme(data: ThemeUtils.darkTheme, child: panel())
              : panel(),
        );
      } else {
        childKey.currentState?.showBottomSheet(
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  @override
  late final RxString videoLabel = ''.obs;
  @override
  int? get timeLength => data.timeLength;
  @override
  BlockConfigMixin get blockConfig => plPlayerController;
  @override
  Player? get player => plPlayerController.videoPlayerController;
  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;
  @override
  bool get autoPlay => _autoPlay.value;
  set autoPlay(bool value) => _autoPlay.value = value;
  @override
  bool get preInitPlayer => plPlayerController.preInitPlayer;
  @override
  int get currPosInMilliseconds =>
      defaultST?.inMilliseconds ?? plPlayerController.positionInMilliseconds;
  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) =>
      plPlayerController.seekTo(duration, isSeek: isSeek);

  @override
  Widget buildItem(Object item, Animation<double> animation) {
    final theme = ThemeUtils.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const .symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${(item as int) + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    UgcIntroController ugcIntroController =
                        Get.find<UgcIntroController>(tag: heroTag);
                    Part part =
                        ugcIntroController.videoDetail.value.pages![item];
                    ugcIntroController.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    logger.d('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item, isSeek: false);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying =
        _autoPlay.value && plPlayerController.playerStatus.isPlaying;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          final child = SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.positionInMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
          if (plPlayerController.darkVideoPage) {
            return Theme(data: ThemeUtils.darkTheme, child: child);
          }
          return child;
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem findVideoByQa(int qa, {bool setCodecs = false}) {
    final video = VideoPlaybackSource.selectVideoTrack(
      data.dash!.video!,
      quality: qa,
      codec: currentDecodeFormats,
      preferredCodecs: preferCodecs,
    );
    if (setCodecs) {
      currentDecodeFormats = VideoDecodeFormatType.fromString(video.codecs!);
    }
    return video;
  }

  void _applyPlaybackSource(VideoPlaybackSource selection) {
    _networkSource = selection.source;
    firstVideo = selection.video;
    currentVideoQa.value = selection.video.quality;
    currentDecodeFormats = selection.codec;
    currentAudioQa = selection.audio == null
        ? null
        : AudioQuality.fromCode(selection.audio!.id);
  }

  /// 切换质量沿用播放意图，原生 open 期间的短暂暂停不改变用户选择。
  void updatePlayer() {
    final quality = currentVideoQa.value;
    if (quality == null || isClosed || !playbackOwner.isActive) return;
    _rememberPlaybackState();
    _applyPlaybackSource(
      VideoPlaybackSource.resolve(
        data,
        videoQuality: quality.code,
        audioQuality: currentAudioQa?.code ?? plPlayerController.cacheAudioQa,
        codec: currentDecodeFormats,
        preferredCodecs: preferCodecs,
      ),
    );
    playerInit();
  }

  void _rememberPlaybackState() {
    _autoPlay.value = plPlayerController.wantsToPlay;
    playedTime = plPlayerController.videoPlayerController?.state.position;
  }

  Future<void>? _initPlayerIfNeeded(
    bool autoFullScreenFlag, {
    bool Function()? isCurrent,
    bool force = false,
  }) {
    if (force ||
        _autoPlay.value ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(
        autoFullScreenFlag: autoFullScreenFlag && _autoPlay.value,
        isCurrent: isCurrent,
      );
    }
    return null;
  }

  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
    bool Function()? isCurrent,
  }) async {
    if (isClosed || !playbackOwner.isActive || !(isCurrent?.call() ?? true)) {
      return;
    }
    final currentMedia = _mediaGuard();
    final source = _networkSource;
    if (!isFileSource && source == null) return;
    bool valid() => currentMedia() && (isCurrent?.call() ?? true);
    Duration? seek = defaultST ?? playedTime;
    if (seek == .zero) seek = null;
    seek ??= getFirstSegment();
    await plPlayerController.setDataSource(
      isFileSource
          ? FileSource(
              dir: args['dirPath'],
              typeTag: entry.typeTag!,
              isMp4: entry.mediaType == 1,
              hasDashAudio: entry.hasDashAudio,
            )
          : source!,
      owner: playbackOwner,
      isValid: valid,
      seekTo: seek,
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
      aid: aid,
      bvid: bvid,
      cid: cid.value,
      autoplay: autoplay ?? _autoPlay.value,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: videoType,
      onInit: () {
        if (!valid()) return;
        videoState.value = true;
        setSubtitle(vttSubtitlesIndex.value);
      },
      width: firstVideo.width,
      height: firstVideo.height,
      volume: volume,
      autoFullScreenFlag: autoFullScreenFlag,
    );

    if (!valid()) return;

    if (!isFileSource) {
      if (plPlayerController.enableBlock) {
        initSkip();
      }

      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo(isCurrent: valid);
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend(isCurrent: valid);
      }
    }

    defaultST = null;
  }

  bool get isQuerying => playbackOwner.isQuerying;

  bool Function() _mediaGuard() {
    final identity = (bvid, cid.value);
    final source = _networkSource;
    final ownsPlayback = playbackOwner.guard();
    return () =>
        !isClosed &&
        ownsPlayback() &&
        identity == (bvid, cid.value) &&
        identical(source, _networkSource);
  }

  final languages = Rxn<List<LanguageItem>>();
  final currLang = Rxn<String>();
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(fromReset: true);
  }

  Future<LoadingState<PlayUrlModel>> Function(int) _captureVideoQuery(
    CancelToken cancelToken,
  ) {
    final request = (
      cid: cid.value,
      bvid: bvid,
      epid: epId,
      seasonId: seasonId,
      videoType: _actualVideoType ?? videoType,
      language: currLang.value,
    );
    return (quality) => VideoHttp.videoUrl(
      cid: request.cid,
      bvid: request.bvid,
      qn: quality,
      epid: request.epid,
      seasonId: request.seasonId,
      tryLook: plPlayerController.tryLook,
      videoType: request.videoType,
      language: request.language,
      voiceBalance: plPlayerController.enableAudioNormalization,
      cancelToken: cancelToken,
    );
  }

  Future<void> _supplementVideoQualities(
    PlayUrlModel response,
    Future<LoadingState<PlayUrlModel>> Function(int) fetch,
    bool Function() isCurrent,
  ) async {
    final quality = response.missingVideoQualityBelowHighest;
    if (quality == -1 || !isCurrent()) return;
    final result = await fetch(quality);
    if (!isCurrent()) return;
    if (result case Success(response: final supplement)) {
      response.dash!.video!.merge(supplement.dash?.video);
    }
  }

  Volume? volume;

  // 视频链接
  /// TODO: merge [DownloadHttp.getVideoUrl].
  Future<void> queryVideoUrl({
    bool fromReset = false,
    bool autoFullScreenFlag = false,
  }) async {
    if (isClosed || !playbackOwner.isActive) return;
    if (isFileSource) return _initPlayerIfNeeded(autoFullScreenFlag);
    if (fromReset && _networkSource != null) _rememberPlaybackState();
    final identity = (bvid, cid.value, epId, seasonId);
    final cancelToken = CancelToken();
    final fetch = _captureVideoQuery(cancelToken);
    await playbackOwner.query(
      (isCurrent) =>
          _queryVideoUrl(fromReset, autoFullScreenFlag, fetch, isCurrent),
      isValid: () =>
          !isClosed &&
          playbackOwner.isActive &&
          identity == (bvid, cid.value, epId, seasonId),
      cancel: cancelToken.cancel,
    );
  }

  Future<void> _queryVideoUrl(
    bool fromReset,
    bool autoFullScreenFlag,
    Future<LoadingState<PlayUrlModel>> Function(int) fetch,
    bool Function() isCurrent,
  ) async {
    if (plPlayerController.enableSponsorBlock && isBlock && !fromReset) {
      querySponsorBlock(bvid: bvid, cid: cid.value, isCurrent: isCurrent);
    }
    if (plPlayerController.cacheVideoQa == null) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      if (!isCurrent()) return;
      plPlayerController
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
      preferCodecs = isWiFi ? Pref.preferCodecs : Pref.preferCodecsCellular;
    }

    if (!isCurrent()) return;
    final result = await fetch(VideoQuality.hdrVivid.code);
    if (!isCurrent()) return;

    if (result case Success(:final response)) {
      if (response.dash != null) {
        await _supplementVideoQualities(response, fetch, isCurrent);
      }
      if (!isCurrent()) return;
      data = response;

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      if (!fromReset) {
        final progress = args.remove('progress');
        if (progress != null) {
          defaultST = Duration(milliseconds: progress);
        } else {
          defaultST = Duration(milliseconds: data.lastPlayTime);
        }
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          resetBlock();
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      if (data.dash == null) {
        if (data.durl?.isNotEmpty == true) {
          _applyPlaybackSource(
            VideoPlaybackSource.resolve(
              data,
              videoQuality: data.quality!,
              audioQuality: plPlayerController.cacheAudioQa,
              preferredCodecs: preferCodecs,
            ),
          );
          _setVideoHeight();
          await _initPlayerIfNeeded(
            autoFullScreenFlag,
            isCurrent: isCurrent,
            force: fromReset,
          );
        } else {
          SmartDialog.showToast('视频资源不存在');
          _autoPlay.value = false;
          videoState.value = false;
          if (plPlayerController.isFullScreen.value) {
            plPlayerController.triggerFullScreen(status: false);
          }
        }
        return;
      }

      _applyPlaybackSource(
        VideoPlaybackSource.resolve(
          data,
          videoQuality: data.findAvailableVideoQuality(
            plPlayerController.cacheVideoQa!,
          ),
          audioQuality: plPlayerController.cacheAudioQa,
          preferredCodecs: preferCodecs,
        ),
      );
      _setVideoHeight();
      await _initPlayerIfNeeded(
        autoFullScreenFlag,
        isCurrent: isCurrent,
        force: fromReset,
      );
    } else {
      _autoPlay.value = false;
      videoState.value = false;
      if (plPlayerController.isFullScreen.value) {
        plPlayerController.triggerFullScreen(status: false);
      }
      result.toast();
    }
  }

  late final List<PostSegmentModel> postList = <PostSegmentModel>[];
  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.positionInMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = PostPanel(
        enableSlide: false,
        videoDetailController: this,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, ({bool isData, String id})> vttSubtitles = {};
  late final vttSubtitlesIndex = (-1).obs;
  bool? inheritedSubtitleEnabled;
  late final showVP = true.obs;
  late final viewPointList = <ViewPointSegment>[].obs;

  // 设定字幕轨道
  int _subtitleGeneration = 0;
  Future<void> setSubtitle(int index) async {
    final generation = ++_subtitleGeneration;
    final currentMedia = _mediaGuard();
    bool valid() => currentMedia() && generation == _subtitleGeneration;
    if (!valid()) return;
    final player = plPlayerController.videoPlayerController;
    if (index <= 0) {
      await player?.setSubtitleTrack(.no());
      if (valid()) vttSubtitlesIndex.value = index;
      return;
    }
    final item = subtitles[index - 1];
    var subtitle = vttSubtitles[index - 1];
    if (subtitle == null) {
      final result = await VideoHttp.getSubtitles(item.subtitleUrl!);
      if (!valid() || result == null) return;
      subtitle = (isData: true, id: result);
      vttSubtitles[index - 1] = subtitle;
    }
    if (!valid()) return;
    await player?.setSubtitleTrack(
      SubtitleTrack(
        subtitle.isData ? 'memory://${subtitle.id}' : subtitle.id,
        item.lanDoc,
        item.lan,
        uri: true,
      ),
    );
    if (valid()) vttSubtitlesIndex.value = index;
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    final currentMedia = _mediaGuard();
    if (!currentMedia()) return;
    final version = graphVersion;
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (!currentMedia() || version != graphVersion) return;
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        logger.w('getSteinEdgeInfo error: ${res.data['message']}');
      }
    } catch (e, stackTrace) {
      logger.w('getSteinEdgeInfo failed', error: e, stackTrace: stackTrace);
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo({required bool Function() isCurrent}) async {
    if (!isCurrent()) return;
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid.value,
      seasonId: seasonId,
      epId: epId,
    );
    if (!isCurrent()) return;
    if (res case Success(:final response)) {
      // interactive video
      late final introCtr = Get.find<UgcIntroController>(tag: heroTag);
      if (isUgc && graphVersion == null) {
        try {
          if (introCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e, stackTrace) {
          logger.w('handle stein failed', error: e, stackTrace: stackTrace);
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        final lastCid = response.lastPlayCid;
        if (lastCid != null && lastCid != 0 && lastCid != cid.value) {
          try {
            final pages = introCtr.videoDetail.value.pages;
            if (pages != null && pages.length > 1) {
              final index = pages.indexWhere((item) => item.cid == lastCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          } catch (_) {}
        }
      }

      if (!isCurrent()) return;
      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          viewPointList.value = response.viewPoints!.map((item) {
            final end = (item.to! / (data.timeLength! / 1000)).clamp(0.0, 1.0);
            return ViewPointSegment(
              end: end,
              title: item.content,
              url: item.imgUrl,
              from: item.from,
              to: item.to,
            );
          }).toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles case final sub? when (sub.isNotEmpty)) {
        _setSubtitle(sub, isCurrent: isCurrent);
      } else if (!Accounts.main.isLogin) {
        final res = await DmGrpc.dmView(aid, cid.value);
        if (!isCurrent()) return;
        if (res case Success(:final response)) {
          if (response.hasSubtitle() &&
              response.subtitle.subtitles.isNotEmpty) {
            _setSubtitle(
              response.subtitle.subtitles
                  .map(
                    (i) => Subtitle(
                      lan: i.lan,
                      lanDoc: i.lanDoc,
                      subtitleUrl: i.subtitleUrl.replaceFirst(
                        RegExp('^https?:'),
                        '',
                      ),
                      isAi: i.type == .AI,
                    ),
                  )
                  .toList()
                ..sort(),
              isCurrent: isCurrent,
            );
          }
        } else {
          res.toast();
        }
      }
    }
  }

  Future<void> _setSubtitle(
    List<Subtitle> sub, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return;
    subtitles.value = sub;
    final selectionGeneration = _subtitleGeneration;
    final preferredIndex = switch (Pref.subtitlePreferenceV2) {
      .off => 0,
      .on => 1,
      .withoutAi => sub.first.lan.startsWith('ai') ? 0 : 1,
      .auto =>
        !sub.first.lan.startsWith('ai') ||
                (PlatformUtils.isMobile &&
                    (await FlutterVolumeController.getVolume() ?? 0.0) <= 0.0)
            ? 1
            : 0,
    };
    if (!isCurrent() || selectionGeneration != _subtitleGeneration) return;
    final inheritedState = inheritedSubtitleEnabled;
    inheritedSubtitleEnabled = null;
    final idx = inheritedState == null
        ? preferredIndex
        : inheritedState
        ? 1
        : 0;
    await setSubtitle(idx);
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.isCompleted &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.completed,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );
      } catch (_) {}
    }
  }

  @override
  void onClose() {
    _subtitleGeneration++;
    playbackOwner.close();
    cid.close();
    if (isFileSource) {
      cacheLocalProgress();
    }
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr?.dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
    subtitles.clear();
    vttSubtitles.clear();
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    _subtitleGeneration++;
    playbackOwner.invalidateRequests();
    if (isFileSource) {
      cacheLocalProgress();
    }

    playedTime = null;
    defaultST = null;
    _networkSource = null;
    currentAudioQa = null;

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // view point
      if (plPlayerController.showViewPoints) {
        viewPointList.clear();
      }

      // sponsor block
      if (blockConfig.enableBlock) {
        resetBlock();
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend({required bool Function() isCurrent}) async {
    if (!isCurrent()) return;
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'aid': aid,
          'bvid': bvid,
          'cid': cid.value,
          'r': 'loader',
        },
        options: Options(
          headers: {
            'user-agent': BrowserUa.pc,
            'origin': 'https://www.bilibili.com',
            'referer': 'https://www.bilibili.com/video/$bvid',
          },
        ),
      );
      if (!isCurrent()) return;
      dynamic json;
      try {
        json = (res.data['modules'] as List).first['params']['data'];
      } catch (_) {
        json = res.data;
      }
      final data = PbpData.fromJson(json);
      final stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      if (!isCurrent()) return;
      dmTrend.value = const Error(null);
      logger.d('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = Get.find<UgcIntroController>(
        tag: heroTag,
      ).videoDetail.value.title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = NoteListPage(
        oid: aid,
        enableSlide: false,
        heroTag: heroTag,
        isStein: graphVersion != null,
        title: title,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item, isSeek: false);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        final ctr = Get.find<UgcIntroController>(tag: heroTag);
        id = ctr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: _autoPlay.value ? heroTag : null,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    UgcIntroController? ugcIntroController;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        ugcIntroController = Get.find<UgcIntroController>(tag: heroTag);
        videoDetail = ugcIntroController.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        logger.w('download ugc failed', error: e, stackTrace: s);
      }
    } else {
      try {
        pgcItem = Get.find<PgcIntroController>(tag: heroTag).pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        logger.w('download pgc failed', error: e, stackTrace: s);
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final index = episodes.indexWhere(
        (e) => e.cid == (seasonCid ?? cid.value),
      );

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: isUgc ? ugcIntroController : null,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: Style.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              _networkSource = NetworkSource(
                videoSource: videoUrl,
                audioSource: audioUrl,
              );
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        } else {
          title = Get.find<PgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        }
      } catch (_) {}
      logger.d(title);
      Get.toNamed(
        '/dlna',
        parameters: {
          'url': url,
          'title': ?title,
        },
      );
    } else {
      res.toast();
    }
  }
}
