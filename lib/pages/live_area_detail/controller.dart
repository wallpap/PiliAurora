import 'dart:math';

import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get_state_manager/src/rx_flutter/rx_ticket_provider_mixin.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class LiveAreaDetailController
    extends CommonListController<List<AreaItem>?, AreaItem>
    with GetTickerProviderStateMixin {
  LiveAreaDetailController(this.areaId, this.parentAreaId);
  final dynamic areaId;
  final dynamic parentAreaId;

  TabController? tabController;

  bool showFirstFrame = false;

  @override
  Object get queryContext => LiveHttp.recommend;

  @override
  void onInit() {
    super.onInit();
    Accounts.recommendChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() => onReload();

  @override
  List<AreaItem>? getDataList(List<AreaItem>? response) {
    tabController?.dispose();
    tabController = null;
    if (response != null && response.isNotEmpty) {
      final initialIndex = max(0, response.indexWhere((e) => e.id == areaId));
      tabController = TabController(
        length: response.length,
        initialIndex: initialIndex,
        vsync: this,
      );
    }
    return response;
  }

  @override
  Future<LoadingState<List<AreaItem>?>> customGetData() =>
      LiveHttp.liveRoomAreaList(parentid: parentAreaId);

  @override
  void onClose() {
    Accounts.recommendChanges.removeListener(_onAccountChanged);
    tabController?.dispose();
    tabController = null;
    super.onClose();
  }
}
