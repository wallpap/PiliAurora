import 'dart:math';

import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/badge.dart';
import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/image_viewer/hero.dart';
import 'package:pili_aurora/common/widgets/stat/stat.dart';
import 'package:pili_aurora/models/common/image_preview_type.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/common/stat_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/season.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/stat.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/widgets/pgc_panel.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/widgets/action_item.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/num_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PgcIntroPage extends StatefulWidget {
  final int? cid;
  final String heroTag;
  final Function showEpisodes;
  final Function showIntroDetail;
  final double maxWidth;
  final bool isLandscape;
  final bool showHeader;
  final bool headerOnly;

  const PgcIntroPage({
    super.key,
    this.cid,
    required this.heroTag,
    required this.showEpisodes,
    required this.showIntroDetail,
    required this.maxWidth,
    required this.isLandscape,
    this.showHeader = true,
    this.headerOnly = false,
  });

  @override
  State<PgcIntroPage> createState() => _PgcIntroPageState();
}

class _PgcIntroPageState extends State<PgcIntroPage> {
  late final PgcIntroController introController;
  late final VideoDetailController videoDetailCtr;

  @override
  void initState() {
    super.initState();
    introController = Get.putOrFind(
      PgcIntroController.new,
      tag: widget.heroTag,
    );
    videoDetailCtr = Get.find<VideoDetailController>(tag: widget.heroTag);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final item = introController.pgcItem;
    final isLandscape = widget.isLandscape;
    Widget sliver = SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showHeader)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                _buildCover(colorScheme, isLandscape, item),
                Expanded(
                  child: _buildInfoPanel(isLandscape, colorScheme, item),
                ),
              ],
            ),
          if (!widget.showHeader && introController.isPgc)
            _buildAboutPanel(colorScheme, item),
          if (!widget.headerOnly) ...[
            if (widget.showHeader) const SizedBox(height: 6),
            if (introController.isPgc && item.stat != null)
              actionGrid(item.stat!, introController),
            if (item.episodes?.isNotEmpty == true ||
                item.section?.any(
                      (section) => section.episodes?.isNotEmpty == true,
                    ) ==
                    true)
              PgcPanel(
                heroTag: widget.heroTag,
                pages: item.episodes ?? const [],
                sections: item.section,
                seasonTitle: item.seasonTitle,
                seasons: item.seasons,
                seasonId: item.seasonId,
                onChangeSeason: _changeSeason,
                cid: videoDetailCtr.cid.value,
                onChangeEpisode: introController.onChangeEpisode,
                onChangeEpisodeList: introController.setPlaybackEpisodes,
                showEpisodes: widget.showEpisodes,
                newEp: item.newEp,
              ),
          ],
        ],
      ),
    );
    if (!introController.isPgc && !widget.headerOnly) {
      final brief = _buildBrief(item);
      if (brief != null) {
        sliver = SliverMainAxisGroup(slivers: [sliver, brief]);
      }
    }
    return SliverPadding(
      padding: const .fromLTRB(
        Style.safeSpace,
        Style.safeSpace,
        Style.safeSpace,
        Style.safeSpace + 16,
      ),
      sliver: sliver,
    );
  }

  void _changeSeason(PgcSeason season) {
    final seasonId = season.seasonId;
    if (seasonId == null || seasonId == introController.seasonId) return;
    PageUtils.viewPgc(seasonId: seasonId);
  }

  Widget _buildAboutPanel(ColorScheme colorScheme, PgcInfoModel item) {
    final score = item.rating?.score;
    final evaluate = item.evaluate?.trim();
    final publishDate =
        item.publish?.releaseDateShow ??
        _formatPublishTime(item.publish?.pubTimeShow);
    final newEpStatus = item.newEp?.desc?.trim();
    final status =
        item.publish?.timeLengthShow ??
        (newEpStatus?.isNotEmpty == true ? newEpStatus : null) ??
        (item.episodes?.isNotEmpty == true
            ? '已完结，全${item.episodes!.length}话'
            : null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.showIntroDetail(
          item,
          introController.videoTags.value,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAboutHeader(
              colorScheme,
              item,
              score,
              publishDate,
              status,
            ),
            if (item.originName?.trim().isNotEmpty == true)
              _buildMetaLine(colorScheme, '原名', item.originName!),
            if (item.alias?.trim().isNotEmpty == true)
              _buildMetaLine(colorScheme, '别名', item.alias!),
            if (item.styles?.isNotEmpty == true)
              _buildMetaTags(colorScheme, item.styles!),
            if (evaluate?.isNotEmpty == true)
              _buildBriefCard(colorScheme, evaluate!),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutHeader(
    ColorScheme colorScheme,
    PgcInfoModel item,
    double? score,
    String? publishDate,
    String? status,
  ) {
    Widget details() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title ?? '',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        if (item.stat != null)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: StatWidget(
                    type: StatType.play,
                    value: item.stat!.view,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: StatWidget(
                    type: StatType.danmaku,
                    value: item.stat!.danmaku,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text(
          '番剧  ${item.areas?.isNotEmpty == true ? item.areas!.first.name ?? '' : ''}',
          style: TextStyle(fontSize: 13, color: colorScheme.outline),
        ),
        const SizedBox(height: 5),
        Text(
          publishDate ?? '暂无开播日期',
          style: TextStyle(fontSize: 13, color: colorScheme.outline),
        ),
        const SizedBox(height: 5),
        Text(
          status ?? '暂无更新信息',
          style: TextStyle(fontSize: 13, color: colorScheme.outline),
        ),
      ],
    );

    Widget coverAndDetails() => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        _buildCover(colorScheme, widget.isLandscape, item, showRating: false),
        Expanded(child: details()),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Expanded(child: coverAndDetails()),
        if (score != null) _buildRatingSummary(colorScheme, item, score),
      ],
    );
  }

  Widget _buildRatingSummary(
    ColorScheme colorScheme,
    PgcInfoModel item,
    double score,
  ) {
    return GestureDetector(
      onTap: () => widget.showIntroDetail(
        item,
        introController.videoTags.value,
        true,
      ),
      child: Container(
        width: 76,
        padding: const EdgeInsets.only(left: 6, top: 20),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: Column(
          children: [
            Text(
              score.toStringAsFixed(1),
              style: TextStyle(
                fontSize: 27,
                height: 1,
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            _ratingStars(colorScheme, score),
            const SizedBox(height: 5),
            Text(
              item.rating?.count == null
                  ? '评分人数'
                  : '${_formatRatingCount(item.rating!.count!)}人',
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ratingStars(ColorScheme colorScheme, double score) {
    final halfStars = (score.clamp(0, 10) / 2 * 2).round().clamp(0, 10);
    final filled = halfStars ~/ 2;
    final hasHalf = halfStars.isOdd;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (index) => Icon(
          index < filled
              ? Icons.star
              : index == filled && hasHalf
              ? Icons.star_half
              : Icons.star_border,
          size: 12,
          color: colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildMetaLine(ColorScheme colorScheme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
        style: TextStyle(fontSize: 13, color: colorScheme.outline),
      ),
    );
  }

  Widget _buildMetaTags(ColorScheme colorScheme, List<String> styles) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '风格  ',
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 5,
              children: styles
                  .map(
                    (style) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.onInverseSurface,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(6),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          style,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBriefCard(ColorScheme colorScheme, String evaluate) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            evaluate,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: colorScheme.outline,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '查看详情 ›',
              style: TextStyle(fontSize: 12, color: colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  String _formatRatingCount(int value) {
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return value.toString();
  }

  String? _formatPublishTime(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final match = RegExp(
      r'(\d{4})\D+(\d{1,2})\D+(\d{1,2}).*?(\d{1,2}):(\d{2})',
    ).firstMatch(value);
    if (match == null) return value;
    String pad(String part) => part.padLeft(2, '0');
    return '${match.group(1)}.${pad(match.group(2)!)}.${pad(match.group(3)!)} '
        '${pad(match.group(4)!)}:${match.group(5)}';
  }

  Widget? _buildBrief(PgcInfoModel item) {
    final img = item.brief?.img;
    if (img != null && img.isNotEmpty) {
      final maxWidth = widget.maxWidth - 24;
      double padding = max(0, maxWidth - 400);
      final imgWidth = maxWidth - padding;
      padding = padding / 2;
      return SliverPadding(
        padding: .only(top: 10, left: padding, right: padding),
        sliver: SliverMainAxisGroup(
          slivers: img.map((e) {
            return SliverToBoxAdapter(
              child: NetworkImgLayer(
                type: .emote,
                src: e.url,
                width: imgWidth,
                height: imgWidth * e.aspectRatio,
              ),
            );
          }).toList(),
        ),
      );
    }
    return null;
  }

  Widget _buildCover(
    ColorScheme colorScheme,
    bool isLandscape,
    PgcInfoModel item, {
    bool showRating = true,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: () => PageUtils.imageView(
            imgList: [SourceModel(url: item.cover!)],
          ),
          child: fromHero(
            tag: item.cover!,
            child: NetworkImgLayer(
              width: 115,
              height: 153,
              src: item.cover!,
            ),
          ),
        ),
        if (showRating && item.rating != null)
          PBadge(
            text: '评分 ${item.rating!.score!}',
            top: null,
            right: 6,
            bottom: 6,
            left: null,
          ),
        if (!introController.isPgc)
          Positioned(
            right: 6,
            bottom: 6,
            child: Obx(() {
              final isFav = introController.isFav.value;
              return iconButton(
                size: 28,
                iconSize: 26,
                tooltip: '${isFav ? '取消' : ''}收藏',
                onPressed: () => introController.onFavPugv(isFav),
                icon: isFav
                    ? const Icon(Icons.star_rounded)
                    : const Icon(Icons.star_border_rounded),
                bgColor: isFav
                    ? colorScheme.secondaryContainer
                    : colorScheme.onInverseSurface,
                iconColor: isFav
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onSurfaceVariant,
              );
            }),
          ),
      ],
    );
  }

  Widget _buildInfoPanel(
    bool isLandscape,
    ColorScheme colorScheme,
    PgcInfoModel item,
  ) {
    if (introController.isPgc) {
      Widget subBtn() => Obx(
        () {
          final isFollowed = introController.isFollowed.value;
          final followStatus = introController.followStatus.value;
          return FilledButton.tonal(
            style: FilledButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 10,
              ),
              visualDensity: VisualDensity.compact,
              foregroundColor: isFollowed ? colorScheme.outline : null,
              backgroundColor: isFollowed ? colorScheme.onInverseSurface : null,
            ),
            onPressed: followStatus == -1
                ? null
                : () {
                    if (isFollowed) {
                      showPgcFollowDialog(
                        context: context,
                        type: introController.pgcType,
                        followStatus: followStatus,
                        onUpdateStatus: (followStatus) {
                          if (followStatus == -1) {
                            introController.pgcDel();
                          } else {
                            introController.pgcUpdate(
                              followStatus,
                            );
                          }
                        },
                      );
                    } else {
                      introController.pgcAdd();
                    }
                  },
            child: Text(
              isFollowed
                  ? '已${introController.pgcType}'
                  : introController.pgcType,
            ),
          );
        },
      );
      Widget title() => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          Expanded(
            child: Text(
              item.title!,
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          subBtn(),
        ],
      );
      List<Widget> desc() => [
        Text(
          item.newEp!.desc!,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        Text.rich(
          TextSpan(
            children: [
              if (item.areas?.isNotEmpty == true)
                TextSpan(text: '${item.areas!.first.name!}  '),
              TextSpan(
                text: item.publish!.pubTimeShow!,
              ),
            ],
          ),
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
      ];
      Widget stat() => Wrap(
        spacing: 6,
        runSpacing: 2,
        children: [
          StatWidget(type: .play, value: item.stat!.view),
          StatWidget(type: .danmaku, value: item.stat!.danmaku),
          if (isLandscape) ...desc(),
        ],
      );
      return GestureDetector(
        onTap: () => widget.showIntroDetail(
          item,
          introController.videoTags.value,
        ),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 153,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title(),
              stat(),
              const SizedBox(height: 5),
              if (!isLandscape) ...desc(),
              const SizedBox(height: 5),
              Expanded(
                child: Text(
                  '简介：${item.evaluate}',
                  style: TextStyle(fontSize: 13, color: colorScheme.outline),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // pugv
    Widget upInfo(int mid, String avatar, String name, {String? role}) =>
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Get.toNamed('/member?mid=$mid'),
          child: Row(
            spacing: 8,
            mainAxisSize: MainAxisSize.min,
            children: [
              NetworkImgLayer(
                src: avatar,
                width: 35,
                height: 35,
                type: ImageType.avatar,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name),
                  if (role != null && role.isNotEmpty)
                    Text(
                      role,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.cooperators?.isNotEmpty == true) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 25,
              children: item.cooperators!.map((e) {
                return upInfo(e.mid!, e.avatar!, e.nickName!, role: e.role);
              }).toList(),
            ),
          ),
          const SizedBox(height: 6),
        ] else if (item.upInfo?.mid != null) ...[
          upInfo(
            item.upInfo!.mid!,
            item.upInfo!.avatar!,
            item.upInfo!.uname!,
          ),
          const SizedBox(height: 6),
        ],
        Text(
          item.title!,
          style: const TextStyle(fontSize: 16),
        ),
        if (item.subtitle?.isNotEmpty == true) ...[
          const SizedBox(height: 5),
          Text(
            item.subtitle!,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget actionGrid(PgcStat stat, PgcIntroController introController) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: ColorScheme.of(context).outlineVariant.withValues(
                alpha: 0.45,
              ),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(
              () => ActionItem(
                animation: introController.tripleAnimation,
                icon: Icon(FontAwesomeIcons.thumbsUp.data),
                selectIcon: Icon(FontAwesomeIcons.solidThumbsUp.data),
                selectStatus: introController.hasLike.value,
                semanticsLabel: '点赞',
                text: NumUtils.numFormat(stat.like),
                onStartTriple: introController.onStartTriple,
                onCancelTriple: introController.onCancelTriple,
              ),
            ),
            Obx(
              () => ActionItem(
                animation: introController.tripleAnimation,
                icon: Icon(FontAwesomeIcons.b.data),
                selectIcon: Icon(FontAwesomeIcons.b.data),
                onTap: introController.actionCoinVideo,
                selectStatus: introController.hasCoin,
                semanticsLabel: '投币',
                text: NumUtils.numFormat(stat.coin),
              ),
            ),
            Obx(
              () => ActionItem(
                animation: introController.tripleAnimation,
                icon: Icon(FontAwesomeIcons.star.data),
                selectIcon: Icon(FontAwesomeIcons.solidStar.data),
                onTap: () => introController.showFavBottomSheet(context),
                onLongPress: () => introController.showFavBottomSheet(
                  context,
                  isLongPress: true,
                ),
                selectStatus: introController.hasFav.value,
                semanticsLabel: '收藏',
                text: NumUtils.numFormat(stat.favorite),
              ),
            ),
            Obx(
              () => ActionItem(
                icon: Icon(FontAwesomeIcons.clock.data),
                selectIcon: Icon(FontAwesomeIcons.solidClock.data),
                onTap: () =>
                    introController.handleAction(introController.viewLater),
                selectStatus: introController.hasLater.value,
                semanticsLabel: '再看',
                text: '再看',
              ),
            ),
            ActionItem(
              icon: Icon(FontAwesomeIcons.shareFromSquare.data),
              onTap: () => introController.actionShareVideo(context),
              selectStatus: false,
              semanticsLabel: '转发',
              text: NumUtils.numFormat(stat.share),
            ),
          ],
        ),
      ),
    );
  }
}
