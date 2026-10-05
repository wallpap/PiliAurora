import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/match.dart';
import 'package:pili_aurora/models/remote/match/match_info/contest.dart';
import 'package:pili_aurora/pages/common/dyn/common_dyn_controller.dart';
import 'package:get/get.dart';

class MatchInfoController extends CommonDynController {
  @override
  final int oid = int.parse(Get.parameters['cid']!);
  @override
  final int replyType = 27;

  @override
  dynamic get sourceId => oid.toString();

  final Rx<LoadingState<MatchContest?>> infoState =
      LoadingState<MatchContest?>.loading().obs;

  @override
  void onInit() {
    super.onInit();
    getMatchInfo();
  }

  Future<void> getMatchInfo() async {
    final res = await MatchHttp.matchInfo(oid);
    if (res.isSuccess) {
      queryData();
    }
    infoState.value = res;
  }
}
