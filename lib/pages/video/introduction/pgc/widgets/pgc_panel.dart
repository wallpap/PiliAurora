import 'dart:async';

import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/horizontal_wheel_scroll.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/new_ep.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/season.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/section.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart'
    hide EpisodeItem;
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PgcPanel extends StatefulWidget {
  const PgcPanel({
    super.key,
    required this.pages,
    this.sections,
    this.seasonTitle,
    this.seasons,
    this.seasonId,
    this.onChangeSeason,
    this.cid,
    required this.onChangeEpisode,
    this.onChangeEpisodeList,
    required this.showEpisodes,
    required this.heroTag,
    this.newEp,
  });

  final List<EpisodeItem> pages;
  final List<Section>? sections;
  final String? seasonTitle;
  final List<PgcSeason>? seasons;
  final int? seasonId;
  final ValueChanged<PgcSeason>? onChangeSeason;
  final int? cid;
  final ValueChanged<BaseEpisodeItem> onChangeEpisode;
  final ValueChanged<List<EpisodeItem>>? onChangeEpisodeList;
  final Function showEpisodes;
  final String heroTag;
  final NewEp? newEp;

  @override
  State<PgcPanel> createState() => _PgcPanelState();
}

class _PgcPanelState extends State<PgcPanel> {
  late List<EpisodeItem> visiblePages;
  late int currentIndex;
  late int selectedSectionIndex;
  late int selectedExtraSectionIndex;
  late final ScrollController listViewScrollCtr;
  late final bool vipStatus;
  late int cid;
  bool _cidUpdateScheduled = false;
  late final VideoDetailController videoDetailCtr;
  late final StreamSubscription<int> _listener;

  List<Section> get _extraSections => [
    for (final section in widget.sections ?? <Section>[])
      if (_isExtraSection(section)) section,
  ];

  bool _isExtraSection(Section section) {
    final title = section.title?.trim() ?? '';
    if (section.episodes?.isNotEmpty != true) return false;
    return title.isEmpty || !title.contains('正片');
  }

  int _indexForCid(List<EpisodeItem> pages, int value) =>
      pages.indexWhere((episode) => episode.cid == value);

  int? _sectionIndexForCid(int value) {
    for (var index = 0; index < (widget.sections?.length ?? 0); index++) {
      if (!_isExtraSection(widget.sections![index])) continue;
      if (widget.sections![index].episodes?.any(
            (episode) => episode.cid == value,
          ) ==
          true) {
        return index;
      }
    }
    return null;
  }

  List<EpisodeItem>? _pagesForSection(int index) {
    if (index < 0 || index >= (widget.sections?.length ?? 0)) return null;
    final pages = widget.sections![index].episodes;
    return pages?.isNotEmpty == true ? pages : null;
  }

  int _extraIndexForSection(int index) {
    if (index < 0 || index >= (widget.sections?.length ?? 0)) return -1;
    return _extraSections.indexWhere(
      (section) => identical(section, widget.sections![index]),
    );
  }

  @override
  void initState() {
    super.initState();
    cid =
        widget.cid ?? (widget.pages.isEmpty ? 0 : widget.pages.first.cid ?? 0);
    selectedSectionIndex = _sectionIndexForCid(cid) ?? -1;
    final extraIndex = _extraIndexForSection(selectedSectionIndex);
    selectedExtraSectionIndex = extraIndex < 0 ? 0 : extraIndex;
    visiblePages = _pagesForSection(selectedSectionIndex) ?? widget.pages;
    currentIndex = _indexForCid(visiblePages, cid);
    listViewScrollCtr = ScrollController(
      initialScrollOffset: currentIndex > 0 ? currentIndex * 164.0 : 0,
    );

    vipStatus = Pref.userInfoCache?.vipStatus != 1;
    videoDetailCtr = Get.find<VideoDetailController>(tag: widget.heroTag);
    widget.onChangeEpisodeList?.call(visiblePages);

    _listener = videoDetailCtr.cid.listen((int value) {
      cid = value;
      selectedSectionIndex = _sectionIndexForCid(cid) ?? -1;
      final currentExtraIndex = _extraIndexForSection(selectedSectionIndex);
      if (currentExtraIndex >= 0) {
        selectedExtraSectionIndex = currentExtraIndex;
      }
      visiblePages = _pagesForSection(selectedSectionIndex) ?? widget.pages;
      currentIndex = _indexForCid(visiblePages, cid);
      widget.onChangeEpisodeList?.call(visiblePages);
      if (!mounted || _cidUpdateScheduled) return;
      _cidUpdateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _cidUpdateScheduled = false;
        if (!mounted) return;
        setState(() {});
        scrollToIndex();
      });
    });
  }

  @override
  void dispose() {
    _listener.cancel();
    listViewScrollCtr.dispose();
    super.dispose();
  }

  void scrollToIndex() {
    final mainIndex = _indexForCid(widget.pages, cid);
    if (mainIndex < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !listViewScrollCtr.hasClients) return;
      listViewScrollCtr.animateTo(
        mainIndex * 164.0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty && _extraSections.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context).colorScheme;
    final playbackPages =
        _pagesForSection(selectedSectionIndex) ?? widget.pages;
    final currentPageIndex = _indexForCid(playbackPages, cid);
    final currEpisode = playbackPages.isEmpty
        ? null
        : playbackPages[currentPageIndex >= 0 ? currentPageIndex : 0];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeading(theme, currEpisode),
        _buildSeasonRail(theme),
        _buildEpisodeRail(theme),
        _buildNowPlaying(theme, currEpisode),
        if (_extraSections.isNotEmpty) _buildRelatedContent(theme),
      ],
    );
  }

  Widget _buildHeading(ColorScheme theme, EpisodeItem? currEpisode) {
    final count = widget.pages.length;
    final status = widget.newEp?.desc?.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            '选集',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              status?.isNotEmpty == true
                  ? status!
                  : count > 0
                  ? '已完结，全$count话'
                  : '暂无内容',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: theme.outline),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(EdgeInsets.zero),
                minimumSize: WidgetStatePropertyAll(Size.zero),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: currEpisode == null
                  ? null
                  : () => widget.showEpisodes(
                      null,
                      null,
                      widget.pages,
                      videoDetailCtr.bvid,
                      videoDetailCtr.aid,
                      cid,
                    ),
              child: const Text('全部', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonRail(ColorScheme theme) {
    final seasons = widget.seasons ?? const <PgcSeason>[];
    if (seasons.isEmpty) {
      final title = widget.seasonTitle?.trim();
      if (title == null || title.isEmpty) return const SizedBox.shrink();
      return _seasonRail(
        theme,
        [PgcSeason(seasonId: widget.seasonId, seasonTitle: title)],
      );
    }
    return _seasonRail(theme, seasons);
  }

  Widget _seasonRail(ColorScheme theme, List<PgcSeason> seasons) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HorizontalWheelScroll(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 7,
            children: [
              for (final season in seasons)
                Material(
                  color: season.seasonId == widget.seasonId
                      ? theme.secondaryContainer
                      : theme.onInverseSurface,
                  borderRadius: const BorderRadius.all(Radius.circular(7)),
                  child: InkWell(
                    borderRadius: const BorderRadius.all(Radius.circular(7)),
                    onTap:
                        season.seasonId == widget.seasonId ||
                            widget.onChangeSeason == null
                        ? null
                        : () => widget.onChangeSeason!(season),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Text(
                        season.seasonTitle ?? '未命名季度',
                        style: TextStyle(
                          fontSize: 12,
                          color: season.seasonId == widget.seasonId
                              ? theme.onSecondaryContainer
                              : theme.onSurfaceVariant,
                          fontWeight: season.seasonId == widget.seasonId
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeRail(ColorScheme theme) {
    return SizedBox(
      height: 84,
      child: HorizontalWheelScroll(
        child: ListView.builder(
          key: const PageStorageKey('pgc-episode-rail'),
          padding: EdgeInsets.zero,
          controller: listViewScrollCtr,
          scrollDirection: Axis.horizontal,
          itemCount: widget.pages.length,
          itemExtent: 164,
          itemBuilder: (context, index) => _buildEpisodeItem(theme, index),
        ),
      ),
    );
  }

  Widget _buildEpisodeItem(ColorScheme theme, int index) {
    final item = widget.pages[index];
    final isPlaying = item.cid == cid;
    final contentTitle = _contentTitle(item, index);
    final color = isPlaying ? theme.primary : theme.onSurface;
    return Container(
      width: 164,
      height: 84,
      margin: const EdgeInsets.only(right: 9),
      child: Material(
        color: isPlaying ? theme.secondaryContainer : theme.onInverseSurface,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: () {
            if (item.badge == '会员' && Accounts.mainEqVideo && vipStatus) {
              SmartDialog.showToast('需要大会员');
            }
            widget.onChangeEpisode(item);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (isPlaying)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Image.asset(
                          Assets.livingChart,
                          color: theme.primary,
                          width: 14,
                          height: 14,
                          cacheWidth: 14.cacheSize(context),
                          semanticLabel: '正在播放',
                        ),
                      ),
                    Expanded(
                      child: Text(
                        item.title ?? '第${index + 1}话',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: color),
                      ),
                    ),
                    if (item.badge?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: item.badge == '会员'
                            ? SvgPicture.asset(
                                Assets.themed(
                                  Assets.vipIcon,
                                  Theme.of(context).brightness,
                                ),
                                height: 15,
                                semanticsLabel: '大会员',
                              )
                            : Text(
                                item.badge!,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: theme.primary,
                                ),
                              ),
                      ),
                  ],
                ),
                if (contentTitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      contentTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: color),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _contentTitle(EpisodeItem item, int index) {
    final values = [item.longTitle, item.showTitle, item.title];
    for (final value in values) {
      final title = value?.trim();
      if (title?.isNotEmpty == true && title != '${index + 1}') return title;
    }
    return null;
  }

  Widget _buildRelatedContent(ColorScheme theme) {
    final section =
        _extraSections[selectedExtraSectionIndex.clamp(
          0,
          _extraSections.length - 1,
        )];
    final pages = section.episodes ?? <EpisodeItem>[];
    return Padding(
      padding: const EdgeInsets.only(top: 19),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '相关内容',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const Expanded(child: SizedBox()),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: const ButtonStyle(
                    padding: WidgetStatePropertyAll(EdgeInsets.zero),
                    minimumSize: WidgetStatePropertyAll(Size.zero),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: pages.isEmpty
                      ? null
                      : () => widget.showEpisodes(
                          null,
                          null,
                          pages,
                          videoDetailCtr.bvid,
                          videoDetailCtr.aid,
                          cid,
                        ),
                  child: const Text('全部', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          HorizontalWheelScroll(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 17,
                children: [
                  for (var index = 0; index < _extraSections.length; index++)
                    GestureDetector(
                      onTap: () =>
                          setState(() => selectedExtraSectionIndex = index),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Text(
                          _extraSections[index].title ?? '附加内容',
                          style: TextStyle(
                            fontSize: 12,
                            color: index == selectedExtraSectionIndex
                                ? theme.primary
                                : theme.outline,
                            fontWeight: index == selectedExtraSectionIndex
                                ? FontWeight.w600
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          _buildExtraRail(theme, pages),
        ],
      ),
    );
  }

  Widget _buildExtraRail(
    ColorScheme theme,
    List<EpisodeItem> pages,
  ) {
    if (pages.isEmpty) return const SizedBox.shrink();
    return HorizontalWheelScroll(
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < pages.length; index++)
              _buildExtraCard(theme, pages[index], index),
          ],
        ),
      ),
    );
  }

  Widget _buildExtraCard(ColorScheme theme, EpisodeItem item, int index) {
    final isPlaying = item.cid == cid;
    return Container(
      width: 164,
      margin: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: () => widget.onChangeEpisode(item),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    NetworkImgLayer(
                      src: item.cover,
                      width: 164,
                      height: 92,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(8),
                      ),
                    ),
                    if (isPlaying)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.primary,
                              width: 2,
                            ),
                            borderRadius: const BorderRadius.all(
                              Radius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    if (item.badge?.isNotEmpty == true)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.error,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(3),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            child: Text(
                              item.badge!,
                              style: TextStyle(
                                fontSize: 9,
                                color: theme.onError,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _contentTitle(item, index) ?? '附加内容 ${index + 1}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isPlaying ? theme.primary : theme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNowPlaying(ColorScheme theme, EpisodeItem? currEpisode) {
    if (currEpisode == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Row(
        children: [
          Image.asset(
            Assets.livingChart,
            color: theme.primary,
            width: 14,
            height: 14,
            cacheWidth: 14.cacheSize(context),
            semanticLabel: '正在播放',
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '正在播放：${currEpisode.longTitle ?? currEpisode.title ?? '当前内容'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: theme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
