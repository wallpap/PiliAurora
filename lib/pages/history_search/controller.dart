import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/history/data.dart';
import 'package:pili_aurora/models/remote/history/list.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart';
import 'package:pili_aurora/pages/common/search/common_search_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter/widgets.dart' show Text;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:collection/collection.dart';

class HistorySearchController
    extends CommonSearchController<HistoryData, HistoryItemModel>
    with CommonMultiSelectMixin<HistoryItemModel>, DeleteItemMixin {
  @override
  Object get queryContext => Accounts.history;

  @override
  Future<LoadingState<HistoryData>> customGetData() async => _isCurrent
      ? UserHttp.searchHistory(
          pn: page,
          keyword: editController.value.text,
          account: account,
        )
      : const Error('账号已切换，请重新打开页面');

  @override
  List<HistoryItemModel>? getDataList(HistoryData response) {
    return response.list;
  }

  final account = Accounts.history;

  bool _deleting = false;
  bool get _isCurrent => !isClosed && identical(account, Accounts.history);

  Future<void> onDelHistory(int index, kid, String business) async {
    final item = loadingState.value.dataOrNull?.firstWhereOrNull(
      (item) => item.kid == kid && item.history.business == business,
    );
    if (item != null) await _deleteItems({item});
  }

  Future<void> _deleteItems(Set<HistoryItemModel> removeList) async {
    final list = loadingState.value.dataOrNull;
    if (_deleting ||
        !_isCurrent ||
        list == null ||
        removeList.isEmpty ||
        !list.toSet().containsAll(removeList)) {
      return;
    }
    _deleting = true;
    SmartDialog.showLoading(msg: '请求中');
    try {
      final result = await UserHttp.delHistory(
        removeList
            .map((item) => '${item.history.business}_${item.kid}')
            .join(','),
        account: account,
      );
      if (!_isCurrent || !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      if (result.isSuccess) {
        await afterDelete(removeList);
        SmartDialog.showToast('已删除');
      } else {
        result.toast();
      }
    } finally {
      _deleting = false;
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  @override
  void onRemove() {
    final removeList = allChecked.toSet();
    showConfirmDialog(
      context: Get.context!,
      title: const Text('提示'),
      content: const Text('确认删除所选历史记录吗？'),
      onConfirm: () => _deleteItems(removeList),
    );
  }
}
