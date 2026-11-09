import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_article/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_article/item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class FavArticleController
    extends CommonListController<FavArticleData, FavArticleItemModel> {
  final _removing = <String, Object>{};

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

  @override
  List<FavArticleItemModel>? getDataList(FavArticleData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.items;
  }

  @override
  Future<LoadingState<FavArticleData>> customGetData() =>
      FavHttp.favArticle(account: Accounts.main, page: page);

  Future<void> onRemove(String id) async {
    final account = Accounts.main;
    final list = loadingState.value.dataOrNull;
    if (isClosed ||
        isLoading ||
        !account.isLogin ||
        list == null ||
        !list.any((item) => item.opusId == id) ||
        _removing.containsKey(id)) {
      return;
    }
    final operation = _removing[id] = Object();
    try {
      final res = await FavHttp.communityAction(
        account: account,
        opusId: id,
        action: 4,
      );
      if (isClosed ||
          isLoading ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      if (res.isSuccess) {
        list.removeWhere((item) => item.opusId == id);
        loadingState.refresh();
        SmartDialog.showToast('已取消收藏');
      } else {
        res.toast();
      }
    } finally {
      if (identical(_removing[id], operation)) _removing.remove(id);
    }
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}
