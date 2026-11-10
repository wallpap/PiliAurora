import 'dart:async';

import 'package:pili_aurora/common/widgets/appbar/appbar.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/flutter/pop_scope.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:pili_aurora/pages/download/controller.dart';
import 'package:pili_aurora/pages/download/danmaku_update.dart';
import 'package:pili_aurora/pages/download/detail/widgets/item.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/pages/download/deletion.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class DownloadDetailPage extends StatefulWidget {
  const DownloadDetailPage({
    super.key,
    required this.pageId,
    required this.title,
    required this.progress,
  });

  final String pageId;
  final String title;
  final ChangeNotifier progress;

  @override
  State<DownloadDetailPage> createState() => _DownloadDetailPageState();
}

class _DownloadDetailPageState extends State<DownloadDetailPage>
    with BaseMultiSelectMixin<BiliDownloadEntryInfo>, GridMixin {
  StreamSubscription? _sub;
  final _downloadItems = RxList<BiliDownloadEntryInfo>();
  final _controller = Get.find<DownloadPageController>();
  final _downloadService = Get.find<DownloadService>();
  final _deletion = DownloadDeletion();
  final _danmakuUpdate = DownloadDanmakuUpdate();

  Future<void> _updateDanmaku() async {
    final updated = await _danmakuUpdate.run(
      service: _downloadService,
      entries: allChecked,
      isCurrent: () => mounted,
    );
    if (!mounted) return;
    for (final entry in updated) {
      entry.checked = false;
    }
    _downloadItems.refresh();
    rxCount.value = allChecked.length;
    if (checkedCount == 0) enableMultiSelect.value = false;
  }

  @override
  RxList<BiliDownloadEntryInfo> get list => _downloadItems;
  @override
  RxList<BiliDownloadEntryInfo> get state => _downloadItems;

  @override
  void initState() {
    super.initState();
    _loadList();
    _sub = _controller.flag.listen((_) {
      _loadList();
    });
  }

  Future<void> _closeSub() async {
    if (_sub != null) {
      await _sub?.cancel();
      _sub = null;
    }
  }

  @override
  void dispose() {
    _closeSub();
    super.dispose();
  }

  void _loadList() {
    final list =
        _controller.pages
            .firstWhereOrNull((e) => e.pageId == widget.pageId)
            ?.entries
          ?..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    if (list != null) {
      _downloadItems.value = list;
    } else {
      _downloadItems.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Obx(() {
      final enableMultiSelect = this.enableMultiSelect.value;
      return popScope(
        canPop: !enableMultiSelect,
        onPopInvokedWithResult: (didPop, result) {
          if (enableMultiSelect) {
            handleSelect();
          }
        },
        child: SimpleScaffold(
          appBar: MultiSelectAppBarWidget(
            ctr: this,
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _updateDanmaku,
                child: Text(
                  '更新',
                  style: TextStyle(color: colorScheme.onSurface),
                ),
              ),
            ],
            child: AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(
                  tooltip: '多选',
                  onPressed: () {
                    if (enableMultiSelect) {
                      handleSelect();
                    } else {
                      this.enableMultiSelect.value = true;
                    }
                  },
                  icon: const Icon(Icons.edit_note),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          body: CustomScrollView(
            slivers: [
              ViewSliverSafeArea(
                sliver: Obx(() {
                  final initialization = _controller.initializationState.value;
                  if (initialization is Error) {
                    return HttpError(
                      errMsg: initialization.toString(),
                      onReload: _controller.retryInitialization,
                    );
                  }
                  if (!initialization.isSuccess) {
                    return const SliverToBoxAdapter(
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (_downloadItems.isNotEmpty) {
                    return SliverGrid.builder(
                      gridDelegate: gridDelegate,
                      itemBuilder: (context, index) {
                        final entry = _downloadItems[index];
                        return DetailItem(
                          entry: entry,
                          progress: widget.progress,
                          downloadService: _downloadService,
                          showTitle: false,
                          onDelete: () => _remove([entry]),
                          controller: this,
                        );
                      },
                      itemCount: _downloadItems.length,
                    );
                  }
                  return const HttpError();
                }),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _remove(
    List<BiliDownloadEntryInfo> selected, {
    bool showLoading = false,
  }) async {
    if (_deletion.busy || !mounted) return;
    final route = ModalRoute.of(context);
    final removed = await _deletion.run(
      items: selected.where(_downloadItems.contains),
      delete: (entry) =>
          _downloadService.deleteDownload(entry: entry, removeList: true),
      entries: (entry) => [entry],
      isCurrent: () => mounted,
      showLoading: showLoading,
      onDeleted: (entry) {
        entry.checked = false;
        _downloadItems.remove(entry);
      },
    );
    if (!mounted) return;
    rxCount.value = list.where((item) => item.checked).length;
    if (rxCount.value == 0) enableMultiSelect.value = false;
    if (removed.isNotEmpty &&
        _downloadItems.isEmpty &&
        route?.isCurrent == true) {
      await _closeSub();
      if (mounted && route?.isCurrent == true) Navigator.of(context).pop();
    }
  }

  @override
  void onRemove() {
    if (_deletion.busy) return;
    final selected = allChecked.toList();
    showConfirmDialog(
      context: context,
      title: const Text('确定删除选中视频？'),
      onConfirm: () => _remove(selected, showLoading: true),
    );
  }
}
