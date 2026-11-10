import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/model_hot_video_item.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class HotController
    extends
        DiscoveryListController<List<HotVideoItemModel>, HotVideoItemModel> {
  @override
  Account get queryAccount => Accounts.get(AccountType.recommend);

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>>> customGetData() =>
      VideoHttp.hotVideoList(
        pn: page,
        ps: 20,
      );
}
