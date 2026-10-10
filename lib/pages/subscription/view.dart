import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';
import 'package:pili_aurora/pages/subscription/controller.dart';
import 'package:pili_aurora/pages/subscription/widgets/item.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SubPage extends StatefulWidget {
  const SubPage({super.key});

  @override
  State<SubPage> createState() => _SubPageState();
}

class _SubPageState extends State<SubPage> with GridMixin {
  final SubController _subController = Get.put(SubController());

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('我的订阅'),
        actions: [
          Obx(
            () => TextButton.icon(
              onPressed: _subController.isCleaning.value
                  ? null
                  : _subController.cleanInvalidSubscriptions,
              icon: _subController.isCleaning.value
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cleaning_services_outlined, size: 20),
              label: Text(_subController.isCleaning.value ? '清理中' : '清除失效内容'),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: refreshIndicator(
        onRefresh: _subController.onRefresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            Obx(
              () => _subController.cleanupProgress.value.isEmpty
                  ? const SliverToBoxAdapter(child: SizedBox.shrink())
                  : SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_subController.cleanupProgress.value),
                      ),
                    ),
            ),
            ViewSliverSafeArea(
              sliver: Obx(
                () => _buildBody(_subController.loadingState.value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<SubItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    _subController.onLoadMore();
                  }
                  final item = response[index];
                  return SubItem(
                    item: item,
                    cancelSub: _subController.isCleaning.value
                        ? null
                        : () => _subController.cancelSub(item),
                  );
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _subController.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _subController.onReload,
      ),
    };
  }
}
