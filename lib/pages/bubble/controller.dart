import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/bubble/category_list.dart';
import 'package:pili_aurora/models/remote/bubble/data.dart';
import 'package:pili_aurora/models/remote/bubble/dyn_list.dart';
import 'package:pili_aurora/models/remote/bubble/sort_info.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' show TabController;

class BubbleController extends CommonListController<BubbleData, DynList>
    with GetSingleTickerProviderStateMixin {
  BubbleController(this.categoryId, {this._tribeId});
  final Object? categoryId;
  final Object? _tribeId;

  late final Object tribeId;
  int? sortType;

  final Rxn<SortInfo> sortInfo = Rxn<SortInfo>();
  TabController? tabController;
  final RxnString tribeName = RxnString();
  final Rxn<List<CategoryList>> tabs = Rxn<List<CategoryList>>();

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    tribeId = _tribeId ?? Get.arguments['id'];
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() {
    sortInfo.value = null;
    tribeName.value = null;
    onReload();
  }

  @override
  List<DynList>? getDataList(BubbleData response) {
    return response.content?.dynList;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<BubbleData> response) {
    if (isRefresh) {
      final data = response.response;
      sortInfo.value = data.sortInfo;
      if (categoryId == null) {
        tribeName.value = data.baseInfo?.tribeInfo?.title;
        if (tabController == null) {
          if (data.category?.categoryList case final categories?
              when categories.isNotEmpty) {
            tabController = TabController(
              length: categories.length,
              vsync: this,
            );
            tabs.value = categories;
          }
        }
      }
    }
    return false;
  }

  @override
  Future<LoadingState<BubbleData>> customGetData() => DynamicsHttp.bubble(
    account: Accounts.main,
    tribeId: tribeId,
    categoryId: categoryId,
    sortType: sortType,
    page: page,
  );

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    tabController?.dispose();
    tabController = null;
    super.onClose();
  }

  Future<void> onSort(int? sortType) {
    this.sortType = sortType;
    return onReload();
  }
}
