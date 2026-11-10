import 'dart:async';

import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/models/remote/download/download_info.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/pages/download/deletion.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart' show Text;
import 'package:get/get.dart';

class DownloadPageController extends GetxController
    with BaseMultiSelectMixin<DownloadPageInfo> {
  final _downloadService = Get.find<DownloadService>();
  final pages = RxList<DownloadPageInfo>();
  final flag = RxInt(0);
  final deletion = DownloadDeletion();

  @override
  List<DownloadPageInfo> get list => pages;
  @override
  RxList<DownloadPageInfo> get state => pages;

  @override
  void onInit() {
    super.onInit();
    _loadList();
    _downloadService.flagNotifier.add(_loadList);
  }

  @override
  void onClose() {
    _downloadService.flagNotifier.remove(_loadList);
    super.onClose();
  }

  Future<void> _loadList() async {
    await _downloadService.waitForInitialization;
    if (isClosed) return;
    if (_downloadService.downloadList.isEmpty) {
      pages.clear();
      rxCount.value = 0;
      enableMultiSelect.value = false;
      flag.value++;
      return;
    }
    final list = <DownloadPageInfo>[];
    for (final entry in _downloadService.downloadList) {
      final pageId = entry.pageId;
      final page = list.firstWhereOrNull((e) => e.pageId == pageId);
      if (page != null) {
        final aSortKey = entry.sortKey;
        final bSortKey = page.sortKey;
        if (aSortKey < bSortKey) {
          page
            ..cover = entry.cover
            ..sortKey = aSortKey;
        }
        page.entries.add(entry);
      } else {
        list.add(
          DownloadPageInfo(
            pageId: pageId,
            dirPath: entry.pageDirPath,
            title: entry.title,
            cover: entry.cover,
            sortKey: entry.sortKey,
            seasonType: entry.ep?.seasonType,
            entries: [entry],
          ),
        );
      }
    }
    final selected = pages
        .where((item) => item.checked)
        .map((item) => item.pageId)
        .toSet();
    for (final item in list) {
      item.checked = selected.contains(item.pageId);
    }
    pages.value = list;
    rxCount.value = list.where((item) => item.checked).length;
    if (rxCount.value == 0) enableMultiSelect.value = false;
    flag.value++;
  }

  Future<void> removeEntry(BiliDownloadEntryInfo entry) async {
    await deletion.run(
      items: [entry],
      delete: (entry) =>
          _downloadService.deleteDownload(entry: entry, removeList: true),
      entries: (entry) => [entry],
      isCurrent: () => !isClosed,
    );
  }

  Future<void> removePages(
    List<DownloadPageInfo> selected, {
    bool showLoading = false,
  }) async {
    await deletion.run(
      items: selected.where(pages.contains),
      delete: (page) => _downloadService.deletePage(pageDirPath: page.dirPath),
      entries: (page) => page.entries,
      isCurrent: () => !isClosed,
      showLoading: showLoading,
    );
  }

  @override
  void onRemove() {
    if (deletion.busy) return;
    final selected = allChecked.toList();
    showConfirmDialog(
      context: Get.context!,
      title: const Text('确定删除选中视频？'),
      onConfirm: () => removePages(selected, showLoading: true),
    );
  }
}
