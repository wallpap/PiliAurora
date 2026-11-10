import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_note/list.dart';
import 'package:pili_aurora/pages/common/multi_select/multi_select_controller.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class FavNoteController
    extends MultiSelectController<List<FavNoteItemModel>?, FavNoteItemModel> {
  FavNoteController(this.isPublish);

  final bool isPublish;
  final isRemoving = false.obs;
  Object? _removal;
  bool _closed = false;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  @override
  final RxBool allSelected = false.obs;

  @override
  void handleSelect({bool checked = false, bool disableSelect = true}) {
    if (isRemoving.value) return;
    allSelected.value = checked;
    super.handleSelect(checked: checked, disableSelect: disableSelect);
  }

  @override
  Future<LoadingState<List<FavNoteItemModel>?>> customGetData() {
    return isPublish
        ? FavHttp.userNoteList(account: Accounts.main, page: page)
        : FavHttp.noteList(account: Accounts.main, page: page);
  }

  @override
  Future<void> onRemove() async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    if (_closed ||
        isClosed ||
        isLoading ||
        isRemoving.value ||
        !account.isLogin ||
        list == null) {
      return;
    }
    final removeList = list.where((item) => item.checked).toSet();
    if (removeList.isEmpty) return;
    final ids = removeList
        .map((item) => isPublish ? item.cvid : item.noteId)
        .toList();
    if (ids.any((id) => int.tryParse('$id') == null || int.parse('$id') <= 0)) {
      SmartDialog.showToast('所选笔记缺少有效标识，请刷新后重试');
      return;
    }
    final operation = _removal = Object();
    isRemoving.value = true;
    bool current() =>
        !_closed && !isClosed && identical(account, Accounts.main);
    try {
      final result = await FavHttp.delNote(
        account: account,
        isPublish: isPublish,
        noteIds: ids.join(','),
      );
      if (!current() ||
          isLoading ||
          !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      if (result.isSuccess) {
        try {
          await afterDelete(removeList);
        } catch (error, stackTrace) {
          logger.w(
            '笔记已删除，本地列表刷新失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
        }
        if (current()) SmartDialog.showToast('删除成功');
      } else {
        result.toast();
      }
    } catch (error, stackTrace) {
      logger.w('删除笔记处理失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) {
        UnknownResult(cause: error, stackTrace: stackTrace).toast();
      }
    } finally {
      if (identical(_removal, operation)) {
        _removal = null;
        isRemoving.value = false;
      }
    }
  }

  @override
  void onSelect(FavNoteItemModel item) {
    if (!isRemoving.value) super.onSelect(item);
  }

  void _resetSelection() {
    rxCount.value = 0;
    allSelected.value = false;
    enableMultiSelect.value = false;
  }

  void _onAccountChanged() {
    _removal = null;
    isRemoving.value = false;
    _resetSelection();
    onReload();
  }

  @override
  Future<void> onRefresh() {
    _resetSelection();
    return super.onRefresh();
  }

  @override
  void onClose() {
    _closed = true;
    _removal = null;
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  void onDisable() {
    if (isRemoving.value) return;
    if (checkedCount != 0) {
      handleSelect();
    }
    enableMultiSelect.value = false;
  }
}
