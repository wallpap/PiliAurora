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
import 'package:pili_aurora/pages/download/detail/widgets/item.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/pages/download/deletion.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage>
    with BaseMultiSelectMixin<BiliDownloadEntryInfo>, GridMixin {
  final _downloadService = Get.find<DownloadService>();
  final _deletion = DownloadDeletion();
  late final _waitDownloadQueue = _downloadService.waitDownloadQueue;
  @override
  RxList<BiliDownloadEntryInfo> get list => _waitDownloadQueue;
  @override
  RxList<BiliDownloadEntryInfo> get state => _waitDownloadQueue;

  @override
  Widget build(BuildContext context) {
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
            child: AppBar(
              title: const Text('正在缓存'),
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
                  final initialization =
                      _downloadService.initializationState.value;
                  if (initialization is Error) {
                    return HttpError(
                      errMsg: initialization.toString(),
                      onReload: _downloadService.initDownloadList,
                    );
                  }
                  if (!initialization.isSuccess) {
                    return const SliverToBoxAdapter(
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (_waitDownloadQueue.isNotEmpty) {
                    return SliverGrid.builder(
                      gridDelegate: gridDelegate,
                      itemCount: _waitDownloadQueue.length,
                      itemBuilder: (context, index) {
                        final entry = _waitDownloadQueue[index];
                        final isCurr = entry.cid == _downloadService.curCid;
                        return DetailItem(
                          entry: entry,
                          downloadService: _downloadService,
                          showTitle: true,
                          isCurr: isCurr,
                          onDelete: () => _remove([entry]),
                          controller: this,
                        );
                      },
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
    final initialCurrent = _downloadService.curDownload.value;
    final wasDownloading = initialCurrent?.status.isDownloading == true;
    var hadFailure = false;
    final snapshot = selected.where(list.contains).toList();
    final removed = await _deletion.run(
      items: snapshot,
      delete: (entry) async {
        try {
          final result = await _downloadService.deleteDownload(
            entry: entry,
            removeQueue: true,
            downloadNext: false,
          );
          if (!result.isSuccess) hadFailure = true;
          return result;
        } catch (_) {
          hadFailure = true;
          rethrow;
        }
      },
      entries: (entry) => [entry],
      isCurrent: () => mounted,
      showLoading: showLoading,
      onDeleted: (entry) => entry.checked = false,
    );
    // 页面释放仅停止后续删除，已确认删除当前任务后仍由服务续行队列。
    if (wasDownloading &&
        !hadFailure &&
        removed.any(
          (entry) => entry.entryDirPath == initialCurrent!.entryDirPath,
        ) &&
        _downloadService.curDownload.value == null) {
      _downloadService.nextDownload();
    }
    if (!mounted) return;
    rxCount.value = list.where((item) => item.checked).length;
    if (rxCount.value == 0) enableMultiSelect.value = false;
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
