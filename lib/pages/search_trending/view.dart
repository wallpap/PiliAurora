import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/sliver/trending_header.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';
import 'package:pili_aurora/pages/search_trending/controller.dart';
import 'package:pili_aurora/utils/color_utils.dart';
import 'package:pili_aurora/utils/extension/context_ext.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class SearchTrendingPage extends ConsumerStatefulWidget {
  const SearchTrendingPage({super.key});

  @override
  ConsumerState<SearchTrendingPage> createState() => _SearchTrendingPageState();
}

class _SearchTrendingPageState extends ConsumerState<SearchTrendingPage> {
  SearchTrendingNotifier get _controller =>
      ref.read(searchTrendingProvider.notifier);

  late double _offset;
  final _scrollRatio = ValueNotifier(0.0);

  @override
  void dispose() {
    _scrollRatio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final size = context.mediaQuerySize;
    final maxWidth = size.width - padding.horizontal;
    final width = size.isPortrait ? maxWidth : min(640.0, maxWidth * 0.6);
    final titleStyle = theme.textTheme.headlineMedium!.copyWith(
      color: Colors.white,
      fontSize: 28,
      fontWeight: FontWeight.w700,
    );
    final titleLayout = TextPainter(
      text: TextSpan(text: 'bilibili热搜', style: titleStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout(maxWidth: width * 0.58 - 24);
    // 系统大字号可能让标题换行，横幅需为导航和标题留出完整高度。
    final height = max(
      width * 528 / 1125,
      padding.top + kToolbarHeight + 12 + titleLayout.height + 24,
    );
    titleLayout.dispose();
    _offset = height - 56 - padding.top;
    return Material(
      child: Stack(
        children: [
          Padding(
            padding: .only(left: padding.left, right: padding.right),
            child: Center(
              child: SizedBox(
                width: width,
                child: refreshIndicator(
                  onRefresh: _controller.refresh,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      TrendingHeader(
                        offset: _offset,
                        onScrollRatioChanged: (value) {
                          if (mounted) _scrollRatio.value = value;
                        },
                        child: SizedBox(
                          width: width,
                          height: height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.asset(
                                Assets.trendingBanner,
                                fit: BoxFit.cover,
                                alignment: Alignment.centerLeft,
                                cacheWidth: width.cacheSize(context),
                                filterQuality: .low,
                                excludeFromSemantics: true,
                              ),
                              Positioned(
                                left: 24,
                                right: width * 0.42,
                                bottom: 24,
                                child: Text(
                                  'bilibili热搜',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: .only(bottom: padding.bottom + 100),
                        sliver: _buildBody(
                          theme,
                          ref.watch(searchTrendingProvider),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: _scrollRatio,
              builder: (context, scrollRatio, child) {
                final flag = maxWidth > width || scrollRatio >= 0.5;
                return AppBar(
                  title: Opacity(
                    opacity: scrollRatio,
                    child: Text(
                      'bilibili热搜',
                      style: TextStyle(
                        color: flag ? null : Colors.white,
                      ),
                    ),
                  ),
                  backgroundColor: theme.colorScheme.surface.withValues(
                    alpha: scrollRatio,
                  ),
                  foregroundColor: flag ? null : Colors.white,
                  systemOverlayStyle: flag
                      ? null
                      : const SystemUiOverlayStyle(
                          statusBarBrightness: Brightness.dark,
                          statusBarIconBrightness: Brightness.light,
                        ),
                  shape: scrollRatio == 1
                      ? Border(
                          bottom: BorderSide(
                            color: theme.colorScheme.outline.withValues(
                              alpha: 0.1,
                            ),
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<SearchTrendingData> loadingState,
  ) {
    switch (loadingState) {
      case Loading():
        return linearLoading;
      case Success(:final response):
        final items = response.list;
        if (items != null && items.isNotEmpty) {
          final divider = Divider(
            height: 1,
            indent: 48,
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          );
          return SliverList.separated(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ListTile(
                dense: true,
                onTap: () => Get.toNamed(
                  '/searchResult',
                  parameters: {'keyword': item.keyword},
                ),
                leading: index < response.topCount
                    ? const Icon(
                        size: 17,
                        Icons.vertical_align_top_outlined,
                        color: Color(0xFFd1403e),
                      )
                    : Text(
                        '${index + 1 - response.topCount}',
                        style: TextStyle(
                          fontWeight: .bold,
                          color: ColourUtils.index2Color(
                            index - response.topCount,
                            theme.colorScheme.outline,
                          ),
                          fontSize: 17,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.showName,
                        maxLines: 1,
                        overflow: .ellipsis,
                        strutStyle: const StrutStyle(height: 1, leading: 0),
                        style: const TextStyle(height: 1, fontSize: 15),
                      ),
                    ),
                    if (item.icon?.isNotEmpty == true) ...[
                      const SizedBox(width: 4),
                      CachedImage(
                        height: 16,
                        memCacheHeight: 16.cacheSize(context),
                        imageUrl: ImageUtils.thumbnailUrl(item.icon!),
                        placeholder: (_, _) => const SizedBox.shrink(),
                      ),
                    ] else if (item.showLiveIcon == true) ...[
                      const SizedBox(width: 4),
                      Image.asset(
                        Assets.livingRect,
                        width: 51,
                        height: 16,
                        cacheHeight: 16.cacheSize(context),
                      ),
                    ],
                  ],
                ),
              );
            },
            separatorBuilder: (context, index) => divider,
          );
        }
        return HttpError(onReload: _controller.refresh);
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: _controller.refresh,
        );
    }
  }
}
