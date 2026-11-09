import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/list.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';

class FavController extends CommonListController<FavFolderData, FavFolderInfo> {
  final account = Accounts.main;

  bool get isCurrent => !isClosed && identical(account, Accounts.main);

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!account.isLogin) {
      loadingState.value = const Error('账号未登录');
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  @override
  List<FavFolderInfo>? getDataList(FavFolderData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.list;
  }

  @override
  Future<LoadingState<FavFolderData>> customGetData() async => isCurrent
      ? FavHttp.userfavFolder(
          account: account,
          pn: page,
          ps: 20,
          mid: account.mid,
        )
      : const Error('账号已切换，请重新打开页面');
}
