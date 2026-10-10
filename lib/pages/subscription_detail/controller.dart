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
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    id = args['id'];
    subInfo = args['subInfo'];
    heroTag = args['heroTag'];

    queryData();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    await super.queryData(isRefresh);
    // 一整页被本地隐藏后继续读取，让后续页的有效视频仍可展示。
    while (Pref.hideInvalidSubscriptionVideos &&
        !isClosed &&
        !isEnd &&
        loadingState.value.dataOrNull?.isEmpty == true) {
      final previousPage = page;
      await super.queryData(false);
      if (page == previousPage) break;
    }
  }

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
    id: id,
    ps: 20,
    pn: page,
  );
}
