import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/list.dart';
import 'package:pili_aurora/pages/common/multi_select/multi_select_controller.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class FavPgcController
    extends MultiSelectController<FavPgcData, FavPgcItemModel> {
  final int type;
  final int followStatus;

  FavPgcController(this.type, this.followStatus);

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  final RxBool allSelected = false.obs;

  @override
  void handleSelect({bool checked = false, bool disableSelect = true}) {
    allSelected.value = checked;
    super.handleSelect(checked: checked, disableSelect: disableSelect);
  }

  @override
  List<FavPgcItemModel>? getDataList(FavPgcData response) {
    return response.list;
  }

  @override
  Future<LoadingState<FavPgcData>> customGetData() => FavHttp.favPgc(
    type: type,
    followStatus: followStatus,
    pn: page,
  );

  void onDisable() {
    if (checkedCount != 0) {
      handleSelect();
    }
    enableMultiSelect.value = false;
  }

  // 取消追番
  Future<void> pgcDel(int? seasonId) async {
    final result = await VideoHttp.pgcDel(seasonId: seasonId);
    if (result case Success(:final response)) {
      loadingState.value.data!.removeWhere(
        (item) => item.seasonId == seasonId,
      );
      loadingState.refresh();
      SmartDialog.showToast(response);
    } else {
      result.toast();
    }
  }

  @override
  void onRemove() {
    assert(false, 'call onUpdateList');
  }

  Future<void> onUpdateList(int followStatus) async {
    final removeList = allChecked.toSet();
    final res = await VideoHttp.pgcUpdate(
      seasonId: removeList.map((item) => item.seasonId).join(','),
      status: followStatus,
    );
    if (res case Success(:final response)) {
      try {
        final ctr = Get.find<FavPgcController>(tag: '$type$followStatus');
        if (ctr.loadingState.value case Success(:final response)) {
          response?.insertAll(
            0,
            removeList.map((item) => item..checked = false),
          );
          ctr
            ..loadingState.refresh()
            ..allSelected.value = false;
        }
      } catch (e, stackTrace) {
        logger.w('fav pgc onUpdate: $e', error: e, stackTrace: stackTrace);
      }
      afterDelete(removeList);
      SmartDialog.showToast(response);
    } else {
      res.toast();
    }
  }

  Future<void> onUpdate(int followStatus, int? seasonId) async {
    final res = await VideoHttp.pgcUpdate(
      seasonId: seasonId.toString(),
      status: followStatus,
    );
    if (res case Success(:final response)) {
      final list = loadingState.value.data!;
      final item = list.where((item) => item.seasonId == seasonId).firstOrNull;
      if (item == null) return;
      list.remove(item);
      loadingState.refresh();
      try {
        final ctr = Get.find<FavPgcController>(tag: '$type$followStatus');
        if (ctr.loadingState.value case Success(:final response)) {
          response?.insert(0, item);
          ctr
            ..loadingState.refresh()
            ..allSelected.value = false;
        }
      } catch (e, stackTrace) {
        logger.w('fav pgc pgcUpdate: $e', error: e, stackTrace: stackTrace);
      }
      SmartDialog.showToast(response);
    } else {
      res.toast();
    }
  }
}
