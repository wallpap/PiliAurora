import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/pages/common/search/common_search_page.dart';
import 'package:pili_aurora/pages/download/detail/widgets/item.dart';
import 'package:pili_aurora/pages/download/search/controller.dart';
import 'package:pili_aurora/pages/download/danmaku_update.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class DownloadSearchPage extends StatefulWidget {
  const DownloadSearchPage({
    super.key,
    required this.progress,
  });

  final ChangeNotifier progress;

  @override
  State<DownloadSearchPage> createState() => _DownloadSearchPageState();
}

class _DownloadSearchPageState
    extends
        CommonSearchPageState<
          DownloadSearchPage,
          List<BiliDownloadEntryInfo>,
          BiliDownloadEntryInfo
        >
    with GridMixin {
  @override
  DownloadSearchController controller = Get.put(DownloadSearchController());
  final _downloadService = Get.find<DownloadService>();
  final _danmakuUpdate = DownloadDanmakuUpdate();

  Future<void> _updateDanmaku() async {
    final source = controller.loadingState.value.dataOrNull;
    if (source == null) return;
    bool current() =>
        mounted &&
        !controller.isClosed &&
        identical(source, controller.loadingState.value.dataOrNull);
    final updated = await _danmakuUpdate.run(
      service: _downloadService,
      entries: controller.allChecked,
      isCurrent: current,
    );
    if (!current()) return;
    for (final entry in updated) {
      entry.checked = false;
    }
    controller.loadingState.refresh();
    controller.rxCount.value = controller.allChecked.length;
    if (controller.checkedCount == 0) {
      controller.enableMultiSelect.value = false;
    }
  }

  @override
  List<Widget>? get extraActions => [
    IconButton(
      tooltip: '多选',
      onPressed: () {
        if (controller.loadingState.value is! Success) {
          return;
        }
        if (controller.enableMultiSelect.value) {
          controller.handleSelect();
        } else {
          controller.enableMultiSelect.value = true;
        }
      },
      icon: const Icon(Icons.edit_note),
    ),
  ];

  @override
  List<Widget>? get multiSelectActions => [
    TextButton(
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: _updateDanmaku,
      child: Text(
        '更新',
        style: TextStyle(color: ColorScheme.of(context).onSurface),
      ),
    ),
  ];

  @override
  Widget buildList(List<BiliDownloadEntryInfo> list) {
    if (list.isNotEmpty) {
      return SliverGrid.builder(
        gridDelegate: gridDelegate,
        itemBuilder: (context, index) {
          final entry = list[index];
          return DetailItem(
            entry: entry,
            progress: widget.progress,
            downloadService: _downloadService,
            showTitle: true,
            onDelete: () => controller.onRemoveSingle(index, entry),
            controller: controller,
          );
        },
        itemCount: list.length,
      );
    }
    return const HttpError();
  }
}
