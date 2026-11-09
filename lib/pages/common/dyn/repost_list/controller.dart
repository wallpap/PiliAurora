import 'package:pili_aurora/grpc/bilibili/app/dynamic/v2.pb.dart'
    show RepostListRsp, DynamicItem;
import 'package:pili_aurora/grpc/dyn.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';

class DynRepostController
    extends CommonListController<RepostListRsp, DynamicItem> {
  DynRepostController(this.id, {int count = -1}) : count = RxInt(count);
  final String id;

  String? _offset;
  final RxInt count;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
  }

  void _onAccountChanged() {
    count.value = -1;
    onReload();
  }

  @override
  List<DynamicItem>? getDataList(RepostListRsp response) {
    count.value = response.totalCount.toInt();
    if (_offset != null && response.offset == _offset) {
      isEnd = true;
      return const [];
    }
    if (!response.hasMore ||
        response.offset.isEmpty ||
        response.offset == _offset) {
      isEnd = true;
    }
    _offset = response.offset;
    return response.list;
  }

  @override
  Future<LoadingState<RepostListRsp>> customGetData() => DynGrpc.repostList(
    account: Accounts.main,
    dynamicId: id,
    offset: _offset,
  );

  @override
  Future<void> onRefresh() {
    _offset = null;
    return super.onRefresh();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}
