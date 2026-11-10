import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 收藏列表与确认弹窗共享账号和来源快照，避免迟到确认操作新账号。
abstract class AccountFavoriteController<R, T>
    extends CommonListController<R, T> {
  final _removing = <int, Object>{};
  bool _closed = false;

  int? itemId(T item);
  Future<LoadingState<void>> removeFavorite(int id, Account account);

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    _removing.clear();
    onReload();
  }

  Future<void> Function()? removalAction(int? id) {
    final account = Accounts.main;
    final source = loadingState.value.dataOrNull;
    if (_closed ||
        isClosed ||
        isLoading ||
        !account.isLogin ||
        id == null ||
        id <= 0 ||
        source == null ||
        !source.any((item) => itemId(item) == id)) {
      return null;
    }
    return () async {
      bool current() =>
          !_closed &&
          !isClosed &&
          identical(account, Accounts.main) &&
          !isLoading &&
          identical(source, loadingState.value.dataOrNull);
      if (!current() || _removing.isNotEmpty) return;
      final operation = _removing[id] = Object();
      try {
        final result = await removeFavorite(id, account);
        if (!current()) return;
        if (result.isSuccess) {
          source.removeWhere((item) => itemId(item) == id);
          loadingState.refresh();
          SmartDialog.showToast('已取消收藏');
          // 删除使偏移分页前移，重新读取边界，避免下一页漏项。
          await onRefresh();
        } else {
          result.toast();
        }
      } finally {
        if (identical(_removing[id], operation)) _removing.remove(id);
      }
    };
  }

  @override
  void onClose() {
    _closed = true;
    _removing.clear();
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}
