import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/data.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/media.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/pages/subscription/hidden_media.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:get/get.dart';

class SubDetailController
    extends CommonListController<SubDetailData, SubDetailItemModel> {
  late int id;
  String? heroTag;
  SubItemModel? subInfo;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    id = args['id'];
    subInfo = args['subInfo'];
    heroTag = args['heroTag'];

    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    subInfo = null;
    onReload();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  int remainingItemsToLoad(int remaining) =>
      Pref.hideInvalidSubscriptionVideos &&
          !isEnd &&
          loadingState.value.dataOrNull?.isEmpty == true
      ? 1
      : 0;

  @override
  List<SubDetailItemModel>? getDataList(SubDetailData response) {
    subInfo = response.info;
    final count = subInfo?.mediaCount;
    if ((response.medias?.length ?? 0) < 20 ||
        (count != null && page * 20 >= count)) {
      isEnd = true;
    }
    return response.medias;
  }

  @override
  void handleListResponse(List<SubDetailItemModel> dataList) {
    if (!Pref.hideInvalidSubscriptionVideos) return;
    final hidden = HiddenSubscriptionMedia(
      GStorage.localCache,
      Accounts.main.mid,
    ).read(21, id);
    dataList.removeWhere((item) => hidden.contains('2:${item.id}'));
  }

  @override
  void checkIsEnd(int length) {
    final count = subInfo?.mediaCount;
    if (count != null && length >= count) {
      isEnd = true;
    }
  }

  @override
  Future<LoadingState<SubDetailData>> customGetData() => FavHttp.favSeasonList(
    account: Accounts.main,
    id: id,
    ps: 20,
    pn: page,
  );
}
