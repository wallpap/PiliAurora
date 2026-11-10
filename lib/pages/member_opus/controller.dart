import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/remote/space/space/tab2.dart';
import 'package:pili_aurora/models/remote/space/space_opus/data.dart';
import 'package:pili_aurora/models/remote/space/space_opus/item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/pages/member/controller.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';

class MemberOpusController
    extends CommonListController<SpaceOpusData, SpaceOpusItemModel> {
  MemberOpusController({
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  String offset = '';
  Rx<SpaceTabFilter> type = const SpaceTabFilter(
    text: "全部图文",
    meta: "all",
    tabName: "图文",
  ).obs;
  List<SpaceTabFilter>? filter;

  @override
  Object get queryContext => Accounts.main;

  void _onAccountChanged() => onReload();

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    filter =
        (Get.isRegistered<MemberController>(tag: heroTag)
                ? Get.find<MemberController>(tag: heroTag).tab2
                : null)
            ?.firstWhereOrNull((e) => e.param == 'contribute')
            ?.items
            ?.firstWhereOrNull((e) => e.param == 'opus')
            ?.filter;
    queryData();
  }

  @override
  Future<void> onRefresh() {
    offset = '';
    return super.onRefresh();
  }

  @override
  List<SpaceOpusItemModel>? getDataList(SpaceOpusData response) {
    offset = response.offset ?? '';
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.items;
  }

  @override
  Future<LoadingState<SpaceOpusData>> customGetData() => MemberHttp.spaceOpus(
    account: Accounts.main,
    hostMid: mid,
    page: page,
    offset: offset,
    type: type.value.meta,
  );
}
