import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/model_hot_video_item.dart';
import 'package:pili_aurora/models/remote/popular/popular_precious/data.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class PopularPreciousController
    extends DiscoveryListController<PopularPreciousData, HotVideoItemModel> {
  @override
  Account get queryAccount => Accounts.get(AccountType.recommend);

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  int? mediaId;

  @override
  List<HotVideoItemModel>? getDataList(PopularPreciousData response) {
    mediaId = response.mediaId;
    return response.list;
  }

  @override
  Future<LoadingState<PopularPreciousData>> customGetData() =>
      VideoHttp.popularPrecious(page: page);
}
