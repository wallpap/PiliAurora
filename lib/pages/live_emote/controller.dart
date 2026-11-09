import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_emote/datum.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LiveEmotePanelController
    extends CommonListController<List<LiveEmoteDatum>?, LiveEmoteDatum>
    with GetTickerProviderStateMixin {
  LiveEmotePanelController(this.roomId);
  final int roomId;
  TabController? tabController;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    tabController?.dispose();
    tabController = null;
    onReload();
  }

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<List<LiveEmoteDatum>?> response,
  ) {
    tabController?.dispose();
    tabController = null;
    if (response.response?.isNotEmpty == true) {
      tabController = TabController(
        length: response.response!.length,
        vsync: this,
      );
    }
    loadingState.value = response;
    return true;
  }

  @override
  Future<LoadingState<List<LiveEmoteDatum>?>> customGetData() =>
      LiveHttp.getLiveEmoticons(roomId: roomId);

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    tabController?.dispose();
    tabController = null;
    super.onClose();
  }
}
