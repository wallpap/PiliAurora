import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart' show Error;
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/blacklist/list.dart';
import 'package:pili_aurora/pages/blacklist/controller.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class BlackListPage extends ConsumerStatefulWidget {
  const BlackListPage({super.key});

  @override
  ConsumerState<BlackListPage> createState() => _BlackListPageState();
}

class _BlackListPageState extends ConsumerState<BlackListPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final snapshot = ref.read(blackListProvider);
    if (!snapshot.isLoading &&
        !snapshot.hasError &&
        snapshot.value?.removingMid != null) {
      return;
    }
    await AsyncValue.guard(() => ref.refresh(blackListProvider.future));
  }

  Future<void> _remove(BlackListItem item) async {
    final before = ref.read(blackListProvider).value;
    final confirmed = await showConfirmDialog(
      context: context,
      title: Text('确定将 ${item.uname ?? item.mid} 移出黑名单？'),
    );
    if (!mounted ||
        !confirmed ||
        !identical(before, ref.read(blackListProvider).value)) {
      return;
    }
    final result = await ref.read(blackListProvider.notifier).remove(item.mid!);
    if (!mounted) return;
    if (result.isSuccess) {
      SmartDialog.showToast('移除成功');
    } else {
      result.toast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(blackListProvider);
    final total = snapshot.isLoading || snapshot.hasError
        ? null
        : snapshot.value?.total;
    return SimpleScaffold(
      appBar: AppBar(title: Text('黑名单管理${total == null ? '' : ': $total'}')),
      body: FeedPagination(
        controller: _scrollController,
        dataRevision: snapshot,
        dataSource: snapshot.value?.source,
        canLoadMore: () {
          final latest = ref.read(blackListProvider);
          return !latest.isLoading &&
              !latest.hasError &&
              (latest.value?.canLoadMore ?? false);
        },
        onLoadMore: ref.read(blackListProvider.notifier).loadMore,
        child: refreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
                ),
                sliver: snapshot.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => const SliverPrototypeExtentList(
                    prototypeItem: MsgFeedTopSkeleton(),
                    delegate: SliverSingleChildDelegate(
                      count: 12,
                      child: MsgFeedTopSkeleton(),
                    ),
                  ),
                  error: (error, _) => HttpError(
                    errMsg: error is Error ? error.toString() : '加载失败，请重试',
                    onReload: _reload,
                  ),
                  data: _buildBody,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BlackListState snapshot) {
    if (snapshot.items.isEmpty) return HttpError(onReload: _reload);
    final style = TextStyle(color: Theme.of(context).colorScheme.outline);
    return SliverMainAxisGroup(
      slivers: [
        SliverList.builder(
          itemCount: snapshot.items.length,
          itemBuilder: (context, index) {
            final item = snapshot.items[index];
            return ListTile(
              visualDensity: .standard,
              onTap: item.mid == null
                  ? null
                  : () => Get.toNamed('/member?mid=${item.mid}'),
              leading: NetworkImgLayer(
                width: 45,
                height: 45,
                type: ImageType.avatar,
                src: item.face,
              ),
              title: Text(
                item.uname ?? '',
                maxLines: 1,
                overflow: .ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                '添加时间: ${DateFormatUtils.format(item.mtime, format: DateFormatUtils.longFormatDs)}',
                maxLines: 1,
                style: style,
                overflow: .ellipsis,
              ),
              dense: true,
              trailing: TextButton(
                onPressed:
                    item.mid == null ||
                        snapshot.isLoadingMore ||
                        snapshot.removingMid != null
                    ? null
                    : () => _remove(item),
                child: Text(snapshot.removingMid == item.mid ? '移除中' : '移除'),
              ),
            );
          },
        ),
        if (snapshot.isLoadingMore)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),
        if (snapshot.pageError != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(
                onPressed: () =>
                    ref.read(blackListProvider.notifier).loadMore(retry: true),
                child: Text(snapshot.pageError!),
              ),
            ),
          ),
      ],
    );
  }
}
