import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class ZoneController extends DiscoveryListController {
  @override
  Account get queryAccount => Accounts.get(AccountType.recommend);

  @override
  bool get supportsPagination => false;

  ZoneController({this.rid, this.seasonType});

  int? rid;
  int? seasonType;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<LoadingState> customGetData() {
    if (rid != null) {
      return VideoHttp.getRankVideoList(rid!);
    }
    if (seasonType == 1) {
      return VideoHttp.pgcRankList(seasonType: seasonType!);
    }
    return VideoHttp.pgcSeasonRankList(seasonType: seasonType!);
  }
}
