import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/later/data.dart';
import 'package:pili_aurora/models/remote/later/list.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart';
import 'package:pili_aurora/pages/common/search/common_search_controller.dart';
import 'package:pili_aurora/pages/later/controller.dart'
    show BaseLaterController;
import 'package:get/get.dart';

class LaterSearchController
    extends CommonSearchController<LaterData, LaterItemModel>
    with
        CommonMultiSelectMixin<LaterItemModel>,
        DeleteItemMixin,
        BaseLaterController {
  dynamic mid;
  dynamic count;

  @override
  void onInit() {
    final args = Get.arguments;
    mid = args['mid'];
    count = args['count'];
    super.onInit();
  }

  @override
  Future<LoadingState<LaterData>> customGetData() async => isLaterCurrent
      ? UserHttp.seeYouLater(
          page: page,
          keyword: editController.value.text,
          account: laterAccount,
        )
      : const Error('账号已切换，请重新打开页面');

  @override
  List<LaterItemModel>? getDataList(LaterData response) {
    return response.list;
  }
}
