import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/article/article_list/article.dart';
import 'package:pili_aurora/models/remote/article/article_list/list.dart';
import 'package:pili_aurora/pages/article_list/controller.dart';
import 'package:pili_aurora/pages/article_list/widgets/item.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/num_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ArticleListPage extends ConsumerStatefulWidget {
  const ArticleListPage({super.key});

  @override
  ConsumerState<ArticleListPage> createState() => _ArticleListPageState();
}

class _ArticleListPageState extends ConsumerState<ArticleListPage>
    with GridMixin {
  late final String _id = Get.parameters['id']!;
  ArticleCollection? get _data {
    final snapshot = ref.read(articleCollectionProvider(_id));
    return !snapshot.isLoading && !snapshot.hasError ? snapshot.value : null;
  }

  Future<void> _reload() async {
    ref.invalidate(articleCollectionProvider(_id));
    try {
      await ref.read(articleCollectionProvider(_id).future);
    } catch (_) {
      /* 页面展示错误。 */
    }
  }

  late EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(articleCollectionProvider(_id));
    final ThemeData theme = Theme.of(context);
    padding = MediaQuery.viewPaddingOf(context);
    return Material(
      color: theme.colorScheme.surface,
      child: refreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildHeader(theme, _data?.list),
            SliverPadding(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
                bottom: padding.bottom + 100,
              ),
              sliver: snapshot.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => gridSkeleton,
                error: (error, _) =>
                    HttpError(errMsg: error.toString(), onReload: _reload),
                data: (data) => _buildBody(theme, Success(data.articles)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget get gridSkeleton => SliverPadding(
    padding: EdgeInsets.only(
      top: padding.top + kToolbarHeight + 120,
    ),
    sliver: super.gridSkeleton,
  );

  Widget _buildBody(
    ThemeData theme,
    LoadingState<List<ArticleListItemModel>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) =>
                    ArticleListItem(item: response[index]),
                itemCount: response.length,
              )
            : HttpError(onReload: _reload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _reload,
      ),
    };
  }

  Widget _buildHeader(ThemeData theme, ArticleListInfo? item) {
    if (item == null) {
      return const SliverToBoxAdapter();
    }
    late final style = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    late final divider = TextSpan(
      text: '  |  ',
      style: TextStyle(color: theme.colorScheme.outline.withValues(alpha: 0.7)),
    );
    return SliverAppBar.medium(
      title: Text(item.name!),
      pinned: true,
      expandedHeight: kToolbarHeight + 127,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          height: 120,
          margin: EdgeInsets.only(
            left: 12 + padding.left,
            right: 12,
            top: padding.top + kToolbarHeight,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.imageUrl?.isNotEmpty == true) ...[
                NetworkImgLayer(
                  width: 91,
                  height: 120,
                  src: item.imageUrl,
                  borderRadius: const BorderRadius.all(
                    Radius.circular(6),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_data?.author != null) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          Get.toNamed('/member?mid=${_data?.author!.mid}'),
                      child: Row(
                        spacing: 10,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NetworkImgLayer(
                            width: 30,
                            height: 30,
                            src: _data?.author!.face,
                            type: ImageType.avatar,
                          ),
                          Flexible(child: Text(_data!.author!.name!)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${NumUtils.numFormat(item.articlesCount)}篇专栏',
                        ),
                        divider,
                        TextSpan(text: '${NumUtils.numFormat(item.words)}个字'),
                        divider,
                        TextSpan(text: '${NumUtils.numFormat(item.read)}次阅读'),
                      ],
                      style: style,
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              '${DateFormatUtils.dateFormat(item.updateTime)}更新',
                        ),
                        divider,
                        TextSpan(text: '文集号: ${item.id}'),
                      ],
                      style: style,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: '浏览器打开',
          onPressed: () => PageUtils.inAppWebview(
            '${HttpString.baseUrl}/read/mobile-readlist/rl$_id',
          ),
          icon: const Icon(Icons.open_in_browser_outlined, size: 19),
        ),
        const SizedBox(width: 10),
      ],
    );
  }
}
