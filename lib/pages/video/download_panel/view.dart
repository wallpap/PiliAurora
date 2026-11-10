import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/badge.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/stat/stat.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/badge_type.dart';
import 'package:pili_aurora/models/common/stat_type.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart'
    as pgc;
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart'
    as ugc;
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/pages/download/view.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/widgets/page.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_select_field.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class DownloadPanel extends StatefulWidget {
  const DownloadPanel({
    super.key,
    required this.index,
    this.pgcItem,
    this.videoDetail,
    required this.episodes,
    required this.scrollController,
    required this.videoDetailController,
    required this.heroTag,
    this.ugcIntroController,
    required this.cidSet,
  });

  final int index;
  final PgcInfoModel? pgcItem;
  final VideoDetailData? videoDetail;
  final List<ugc.BaseEpisodeItem> episodes;
  final ScrollController scrollController;
  final VideoDetailController videoDetailController;
  final String heroTag;
  final UgcIntroController? ugcIntroController;
  final Set<int> cidSet;

  @override
  State<DownloadPanel> createState() => _DownloadPanelState();
}

class _DownloadPanelState extends State<DownloadPanel> {
  final DownloadService _downloadService = Get.find<DownloadService>();
  final ListController _listController = ListController();

  late final cidSet = widget.cidSet;
  final _creating = <int>{};
  VideoQuality _quality = VideoQuality.fromCode(Pref.defaultVideoQa);
  AudioQuality _audioQuality = AudioQuality.fromCode(Pref.defaultAudioQa);

  @override
  void initState() {
    super.initState();
    if (widget.index != -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _listController.jumpToItem(
          index: widget.index,
          scrollController: widget.scrollController,
          alignment: 0,
        );
      });
    }
  }

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.colorScheme.outline.withValues(alpha: 0.2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildHeader(theme),
        _buildBody(theme),
        Divider(height: 1, color: dividerColor),
        _buildFooter(theme, dividerColor),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final textStyle = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        children: [
          Row(
            spacing: 16,
            children: [
              Text('最高画质', style: textStyle),
              AppSelectField<VideoQuality>(
                value: _quality,
                label: '最高画质',
                selectedLabel: _quality.desc,
                width: 110,
                menuWidth: 240,
                options: [
                  for (final quality in VideoQuality.values)
                    (quality, quality.desc),
                ],
                onSelected: (value) {
                  _quality = value;
                  (context as Element).markNeedsBuild();
                },
              ),
              if (kDebugMode || PlatformUtils.isMobile) ...[
                const Spacer(),
                StreamBuilder(
                  stream: Connectivity().onConnectivityChanged,
                  builder: (context, snapshot) {
                    if (snapshot.data case final data?) {
                      final network = data.contains(ConnectivityResult.wifi)
                          ? 'WIFI'
                          : '数据';
                      return Text('当前网络：$network', style: textStyle);
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            spacing: 16,
            children: [
              Text('音质', style: textStyle),
              AppSelectField<AudioQuality>(
                value: _audioQuality,
                label: '音质',
                selectedLabel: _audioQuality.desc,
                width: 110,
                menuWidth: 220,
                options: [
                  for (final quality in AudioQuality.values)
                    (quality, quality.desc),
                ],
                onSelected: (value) {
                  _audioQuality = value;
                  (context as Element).markNeedsBuild();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final episodes = widget.episodes;
    return Expanded(
      child: Material(
        type: MaterialType.transparency,
        child: CustomScrollView(
          controller: widget.scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 100),
              sliver: SuperSliverList.builder(
                itemCount: episodes.length,
                listController: _listController,
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  final hasParts =
                      episode is ugc.EpisodeItem && episode.pages!.length > 1;
                  Widget child = _buildItem(
                    theme: theme,
                    index: index,
                    hasParts: hasParts,
                    episode: episode,
                    isCurrentIndex: index == widget.index,
                  );
                  if (hasParts) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        child,
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: PagesPanel(
                            list: episode.pages,
                            cover: episode.arc?.pic,
                            heroTag: widget.heroTag,
                            ugcIntroController: widget.ugcIntroController!,
                            bvid: episode.bvid ?? IdUtils.av2bv(episode.aid!),
                            cidSet: cidSet,
                            onDownload: (Part part) => _onDownload(
                              index: index,
                              episode: part,
                              parent: episode,
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return child;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  late final int? vipStatus = Pref.userInfoCache?.vipStatus;
  @pragma('vm:notify-debugger-on-exception')
  Future<bool> _onDownload({
    required int index,
    required ugc.BaseEpisodeItem episode,
    bool isFromList = false,
    bool isDownloadAll = false,
    ugc.EpisodeItem? parent,
  }) async {
    if (!mounted) return false;
    final cid = episode.cid;
    // on download
    if (cid == null) {
      SmartDialog.showToast('视频信息不完整，无法缓存');
      return false;
    }

    if (cidSet.contains(cid)) {
      if (kDebugMode) {
        SmartDialog.showToast('downloaded');
      }
      return false;
    }

    if (kReleaseMode && episode.badge == '会员' && Accounts.mainEqVideo) {
      if (vipStatus != 1) {
        if (!isDownloadAll) {
          SmartDialog.showToast('需要大会员');
        }
        return false;
      }
    }

    if (episode is ugc.EpisodeItem) {
      final pages = episode.pages;
      if (pages == null || pages.isEmpty) {
        SmartDialog.showToast('视频分 P 信息不完整，请重新打开后重试');
        return false;
      }
      if (pages.length > 1) {
        if (isFromList && kDebugMode) {
          SmartDialog.showToast('hasParts');
        }
        if (isDownloadAll) {
          var created = false;
          for (int i = 0; i < pages.length; i++) {
            created =
                await _onDownload(
                  index: i,
                  episode: pages[i],
                  parent: episode,
                ) ||
                created;
          }
          return created;
        }
        return false;
      }
    }

    if (!_creating.add(cid)) return false;
    try {
      LoadingState<void> result;
      switch (episode) {
        case Part part:
          result = await _downloadService.downloadVideo(
            part,
            parent == null ? widget.videoDetail : null,
            parent,
            _quality,
            _audioQuality,
          );
          break;
        case ugc.EpisodeItem episode:
          result = await _downloadService.downloadVideo(
            episode.pages!.first,
            null,
            episode,
            _quality,
            _audioQuality,
          );
          break;
        case pgc.EpisodeItem episode:
          result = await _downloadService.downloadBangumi(
            index,
            widget.pgcItem!,
            episode,
            _quality,
            _audioQuality,
          );
          break;
        default:
          return false;
      }
      if (!mounted) return false;
      if (!result.isSuccess) {
        if (result is! DownloadCancelled) result.toast();
        return false;
      }
      cidSet.add(cid);
      return true;
    } catch (e, s) {
      logger.e('创建下载失败', error: e.runtimeType, stackTrace: s);
      if (mounted) SmartDialog.showToast('创建下载失败，请重试');
    } finally {
      _creating.remove(cid);
    }
    return false;
  }

  Widget _buildItem({
    required ThemeData theme,
    required int index,
    required bool hasParts,
    required bool isCurrentIndex,
    required ugc.BaseEpisodeItem episode,
  }) {
    late String title;
    num? duration;
    int? pubdate;
    int? view;
    int? danmaku;
    bool? isCharging;
    int? cid;

    String? cover;
    bool? cacheWidth;

    switch (episode) {
      case Part part:
        cid = part.cid;
        cover = part.firstFrame ?? widget.videoDetail?.pic;
        title = part.part ?? widget.videoDetail!.title!;
        duration = part.duration;
        pubdate = part.ctime;
        cacheWidth = part.dimension?.cacheWidth;
        break;
      case ugc.EpisodeItem item:
        cid = item.cid;
        title = item.title!;
        if (item.arc case final arc?) {
          cover = arc.pic;
          duration = arc.duration;
          pubdate = arc.pubdate;
          if (arc.stat case final stat?) {
            view = stat.view;
            danmaku = stat.danmaku;
          }
          cacheWidth = arc.dimension?.cacheWidth;
        }
        if (item.attribute == 8) {
          isCharging = true;
        }
        break;
      case pgc.EpisodeItem item:
        cid = item.cid;
        title = item.showTitle ?? item.title!;
        cover = item.cover;
        if (item.from == 'pugv') {
          duration = item.duration;
          view = item.play;
        } else {
          duration = item.duration == null ? null : item.duration! ~/ 1000;
        }
        pubdate = item.pubTime;
        cacheWidth = item.dimension?.cacheWidth;
        break;
    }
    late final primary = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: SizedBox(
        height: 110,
        child: Builder(
          builder: (context) {
            return Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () async {
                  if (await _onDownload(
                        index: index,
                        episode: episode,
                        isFromList: true,
                      ) &&
                      context.mounted) {
                    (context as Element).markNeedsBuild();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Style.safeSpace,
                    vertical: 5,
                  ),
                  child: Row(
                    spacing: 10,
                    children: [
                      if (cover?.isNotEmpty == true)
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            NetworkImgLayer(
                              src: cover,
                              width: 160,
                              height: 100,
                              cacheWidth: cacheWidth,
                            ),
                            if (duration != null && duration > 0)
                              PBadge(
                                text: DurationUtils.formatDuration(duration),
                                right: 6.0,
                                bottom: 6.0,
                                type: PBadgeType.gray,
                              ),
                            if (isCharging == true)
                              const PBadge(
                                text: '充电专属',
                                top: 6,
                                right: 6,
                                type: PBadgeType.error,
                              )
                            else if (episode.badge != null)
                              PBadge(
                                text: episode.badge,
                                top: 6,
                                right: 6,
                                type: switch (episode.badge) {
                                  '预告' => PBadgeType.gray,
                                  '限免' => PBadgeType.free,
                                  _ => PBadgeType.primary,
                                },
                              ),
                          ],
                        )
                      else if (isCurrentIndex)
                        Image.asset(
                          Assets.livingStatic,
                          color: primary,
                          height: 12,
                          cacheHeight: 12.cacheSize(context),
                          semanticLabel: '正在播放：',
                        ),
                      Expanded(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    textAlign: TextAlign.start,
                                    style: TextStyle(
                                      fontSize:
                                          theme.textTheme.bodyMedium!.fontSize,
                                      height: 1.42,
                                      letterSpacing: 0.3,
                                      fontWeight: isCurrentIndex
                                          ? FontWeight.bold
                                          : null,
                                      color: isCurrentIndex ? primary : null,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (pubdate != null)
                                  Text(
                                    DateFormatUtils.format(pubdate),
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1,
                                      color: theme.colorScheme.outline,
                                      overflow: TextOverflow.clip,
                                    ),
                                  ),
                                const SizedBox(height: 2),
                                Row(
                                  spacing: 8,
                                  children: [
                                    if (view != null)
                                      StatWidget(
                                        value: view,
                                        type: StatType.play,
                                      ),
                                    if (danmaku != null)
                                      StatWidget(
                                        value: danmaku,
                                        type: StatType.danmaku,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            if (!hasParts && cidSet.contains(cid))
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Icon(
                                  size: 13,
                                  color: theme.colorScheme.secondary.withValues(
                                    alpha: 0.8,
                                  ),
                                  FontAwesomeIcons.circleDown.data,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, Color dividerColor) {
    return Container(
      color: theme.hoverColor,
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        children: [
          _buildBottomBtn(
            text: '缓存全部',
            onTap: () {
              showConfirmDialog(
                context: context,
                title: const Text('确定缓存全部？'),
                onConfirm: () async {
                  for (int i = 0; i < widget.episodes.length; i++) {
                    if (!mounted) break;
                    await _onDownload(
                      index: i,
                      episode: widget.episodes[i],
                      isDownloadAll: true,
                    );
                  }
                  if (mounted) setState(() {});
                },
              );
            },
          ),
          SizedBox(
            height: 20,
            child: VerticalDivider(
              width: 1,
              color: dividerColor,
            ),
          ),
          _buildBottomBtn(
            text: '查看缓存',
            onTap: () => Navigator.of(context).push(
              GetPageRoute(page: () => const DownloadPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBtn({
    required String text,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          width: double.infinity,
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
