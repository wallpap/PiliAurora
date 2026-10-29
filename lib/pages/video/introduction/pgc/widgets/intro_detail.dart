import 'package:pili_aurora/common/widgets/keep_alive_wrapper.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show tabBarScrollPhysics;
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/common/widgets/video_tag_colors.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/stat/stat.dart';
import 'package:pili_aurora/models/common/stat_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/video/video_tag/data.dart';
import 'package:pili_aurora/pages/common/slide/common_slide_page.dart';
import 'package:pili_aurora/pages/pgc_review/view.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PgcIntroPanel extends CommonSlidePage {
  final PgcInfoModel item;
  final List<VideoTagItem>? videoTags;
  final bool openReviews;

  const PgcIntroPanel({
    super.key,
    required this.item,
    super.enableSlide,
    this.videoTags,
    this.openReviews = false,
  });

  @override
  State<PgcIntroPanel> createState() => _IntroDetailState();
}

class _IntroDetailState extends State<PgcIntroPanel>
    with TickerProviderStateMixin, CommonSlideMixin {
  late final ScrollController _controller;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.openReviews ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  dividerHeight: 0,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(text: '详情'),
                    Tab(text: '点评'),
                  ],
                  onTap: (index) {
                    if (!_tabController.indexIsChanging) {
                      if (index == 0) {
                        _controller.animToTop();
                      }
                    }
                  },
                ),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close, size: 20),
                onPressed: Get.back,
              ),
              const SizedBox(width: 2),
            ],
          ),
          Expanded(
            child: enableSlide ? slideList(theme) : buildList(theme),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildList(ThemeData theme) {
    return TabBarView(
      controller: _tabController,
      physics: tabBarScrollPhysics,
      horizontalDragGestureRecognizer: horizontalDragGestureRecognizer,
      children: [
        KeepAliveWrapper(child: _buildInfo(theme)),
        PgcReviewPage(
          name: widget.item.title!,
          mediaId: widget.item.mediaId,
        ),
      ],
    );
  }

  Widget _buildInfo(ThemeData theme) {
    final TextStyle smallTitle = TextStyle(
      fontSize: 12,
      color: theme.colorScheme.onSurface,
    );
    final TextStyle textStyle = TextStyle(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final alias = widget.item.alias?.trim().isNotEmpty == true
        ? widget.item.alias!.trim()
        : widget.item.seasonTitle?.trim();
    return ListView(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        top: 14,
        bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
      ),
      children: [
        _buildHeader(theme, smallTitle),
        if (widget.item.originName?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 16),
          _detailLine('原名', widget.item.originName!, textStyle),
        ],
        if (alias?.isNotEmpty == true && alias != widget.item.title) ...[
          const SizedBox(height: 10),
          _detailLine('别名', alias!, textStyle),
        ],
        if (widget.item.styles?.isNotEmpty == true) ...[
          const SizedBox(height: 14),
          _sectionTitle(theme, '风格'),
          const SizedBox(height: 6),
          _buildTags(widget.item.styles!),
        ],
        if (widget.item.evaluate?.isNotEmpty == true) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '简介'),
          const SizedBox(height: 4),
          SelectionText(
            widget.item.evaluate!,
            style: textStyle,
          ),
        ],
        if (widget.item.actors?.isNotEmpty == true) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '角色声优'),
          const SizedBox(height: 4),
          SelectionText(
            widget.item.actors!,
            style: textStyle,
          ),
        ],
        if (widget.item.staff?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '制作信息'),
          const SizedBox(height: 4),
          SelectionText(widget.item.staff!, style: textStyle),
        ] else if (widget.item.cooperators?.isNotEmpty == true) ...[
          const SizedBox(height: 20),
          _sectionTitle(theme, '制作信息'),
          const SizedBox(height: 4),
          ...widget.item.cooperators!.map(
            (e) => Text(
              '${e.role?.trim().isNotEmpty == true ? '${e.role}: ' : ''}${e.nickName ?? ''}',
              style: textStyle,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHeader(ThemeData theme, TextStyle smallTitle) {
    final item = widget.item;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: [
        NetworkImgLayer(src: item.cover, width: 115, height: 153),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectionText(
                item.title ?? '',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
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
              const SizedBox(height: 13),
              Text(
                '番剧  ${item.areas?.isNotEmpty == true ? item.areas!.first.name ?? '' : ''}',
                style: smallTitle,
              ),
              const SizedBox(height: 6),
              Text(
                item.publish?.releaseDateShow ??
                    _formatAirDate(item.publish?.pubTimeShow),
                style: smallTitle,
              ),
              const SizedBox(height: 6),
              Text(
                item.publish?.timeLengthShow ?? item.newEp?.desc ?? '暂无更新信息',
                style: smallTitle,
              ),
            ],
          ),
        ),
        if (item.rating?.score case final score?)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _tabController.animateTo(1),
            child: Container(
              width: 82,
              padding: const EdgeInsets.only(left: 6, top: 28),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Column(
                children: [
                  Text(
                    score.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 28,
                      height: 1,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                  _ratingStars(theme, score),
                  const SizedBox(height: 5),
                  Text(
                    item.rating?.count == null
                        ? '查看点评'
                        : '${_formatCount(item.rating!.count!)}人',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _ratingStars(ThemeData theme, double score) {
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
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) => Text(
    title,
    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _detailLine(String label, String value, TextStyle style) => RichText(
    text: TextSpan(
      style: style,
      children: [
        TextSpan(
          text: '$label  ',
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        TextSpan(text: value),
      ],
    ),
  );

  Widget _buildTags(List<String> tags) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: tags.map(
      (tag) {
        final colors = Theme.of(context).colorScheme;
        return SearchText(
          fontSize: 13,
          text: tag,
          bgColor: VideoTagColors.plainBackground(
            isDark: colors.brightness == Brightness.dark,
            onSurface: colors.onSurface,
            onSurfaceVariant: colors.onSurfaceVariant,
          ),
          textColor: VideoTagColors.plainForeground(
            isDark: colors.brightness == Brightness.dark,
            onSurface: colors.onSurface,
            onSurfaceVariant: colors.onSurfaceVariant,
          ),
          onTap: (tagName) => Get.toNamed(
            '/searchResult',
            parameters: {'keyword': tagName},
          ),
          onLongPress: Utils.copyText,
        );
      },
    ).toList(),
  );

  String _formatCount(int value) {
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return value.toString();
  }

  String _formatAirDate(String? value) {
    final match = value == null
        ? null
        : RegExp(r'(\d{4})\D+(\d{1,2})\D+(\d{1,2})').firstMatch(value);
    if (match == null) return value ?? '暂无开播日期';
    return '${match.group(1)}年${match.group(2)}月${match.group(3)}日开播';
  }
}
