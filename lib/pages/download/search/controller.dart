import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:pili_aurora/pages/common/search/common_search_controller.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/pages/download/deletion.dart';
import 'package:flutter/widgets.dart' show Text;
import 'package:get/get.dart';

class DownloadSearchController
    extends
        CommonSearchController<
          List<BiliDownloadEntryInfo>,
          BiliDownloadEntryInfo
        >
    with BaseMultiSelectMixin<BiliDownloadEntryInfo> {
  final _downloadService = Get.find<DownloadService>();
  final deletion = DownloadDeletion();

  @override
  List<BiliDownloadEntryInfo> get list => loadingState.value.data!;
  @override
  Rx<LoadingState<List<BiliDownloadEntryInfo>?>> get state => loadingState;

  @override
  Future<LoadingState<List<BiliDownloadEntryInfo>>> customGetData() async {
    final initialization = await _downloadService.waitForInitialization;
    if (initialization is Error) return initialization;
    if (!initialization.isSuccess) return const Error('下载记录尚未读取完成');
    final text = editController.text.toLowerCase();
    return Success(
      _downloadService.downloadList
          .where(
            (e) =>
                e.title.toLowerCase().contains(text) ||
                e.showTitle.toLowerCase().contains(text) ||
                (e.ownerName?.toLowerCase().contains(text) ?? false),
          )
          .toList(),
    );
  }

  Future<void> onRemoveSingle(int index, BiliDownloadEntryInfo entry) =>
      removeEntries([entry]);

  Future<void> removeEntries(
    List<BiliDownloadEntryInfo> entries, {
    bool showLoading = false,
  }) async {
    final source = loadingState.value.dataOrNull;
    if (source == null) return;
    bool current() =>
        !isClosed && identical(source, loadingState.value.dataOrNull);
    await deletion.run(
      items: entries.where(source.contains),
      delete: (entry) =>
          _downloadService.deleteDownload(entry: entry, removeList: true),
      entries: (entry) => [entry],
      isCurrent: current,
      showLoading: showLoading,
      onDeleted: (entry) {
        source.remove(entry);
        entry.checked = false;
        loadingState.refresh();
      },
    );
    if (current()) {
      rxCount.value = source.where((entry) => entry.checked).length;
      if (rxCount.value == 0) enableMultiSelect.value = false;
    }
  }

  @override
  void onRemove() {
    if (deletion.busy) return;
    final source = loadingState.value.dataOrNull;
    final selected = allChecked.toList();
    showConfirmDialog(
      context: Get.context!,
      title: const Text('确定删除选中视频？'),
      onConfirm: () async {
        if (!isClosed && identical(source, loadingState.value.dataOrNull)) {
          await removeEntries(selected, showLoading: true);
        }
      },
    );
  }
}
